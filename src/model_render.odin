package main

import "core:log"
import "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"

// Draws the meshes mesh.odin loaded: the props standing on the map and the
// weapon in the player's hands.
//
// The two are kept apart because they change at different rates. Props are
// placed once at load and never move, so their instances live in a device-local
// buffer and their draw list is built once -- identical instances collapse into
// a single instanced draw on the way in. The viewmodel is rewritten every frame
// and gets a mapped buffer, like every other per-frame stream in the renderer.

MAX_VIEW_MODEL_INSTANCES :: 8

// std430-compatible and the layout the instance attributes describe.
Model_Instance :: struct {
	model:  linalg.Matrix4f32,
	params: [4]f32, // receives shadow (0/1), rest reserved
}

// 80 bytes of content in 96: Odin aligns a Matrix4f32 to 32, so the struct is
// padded up to a multiple of that. Vulkan only cares that the stride and the
// attribute offsets agree with what is written here, and both come from these
// same declarations.
#assert(size_of(Model_Instance) == 96)
#assert(offset_of(Model_Instance, params) == 64)

// One draw: a mesh and the run of instances that share it.
Model_Batch :: struct {
	mesh:           Mesh,
	first_instance: u32,
	instance_count: u32,
}

Model_Renderer :: struct {
	pipeline:         Pipeline,
	static_buffer:    vk.Buffer,
	static_memory:    vk.DeviceMemory,
	static_batches:   []Model_Batch,
	static_count:     u32,
	view_buffers:     [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	view_memories:    [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	view_mapped:      [MAX_FRAMES_IN_FLIGHT]rawptr,
	view_batches:     [dynamic]Model_Batch,
	view_instances:   [dynamic]Model_Instance,
}

model_renderer: Model_Renderer

model_binding_descriptions :: proc() -> [2]vk.VertexInputBindingDescription {
	return {
		{binding = 0, stride = size_of(Vertex), inputRate = .VERTEX},
		{binding = 1, stride = size_of(Model_Instance), inputRate = .INSTANCE},
	}
}

// The world's five vertex attributes, then the instance transform. A mat4
// attribute is four vec4 locations; there is no wider vertex format.
model_attribute_descriptions :: proc() -> [10]vk.VertexInputAttributeDescription {
	vertex := vertex_attribute_descriptions()
	return {
		vertex[0],
		vertex[1],
		vertex[2],
		vertex[3],
		vertex[4],
		{location = 5, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 0},
		{location = 6, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 16},
		{location = 7, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 32},
		{location = 8, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 48},
		{
			location = 9,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Model_Instance, params)),
		},
	}
}

// The depth-only pass reads the position and the model matrix and nothing else.
model_shadow_attribute_descriptions :: proc() -> [5]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, pos)),
		},
		{location = 1, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 0},
		{location = 2, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 16},
		{location = 3, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 32},
		{location = 4, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 48},
	}
}

create_model_renderer :: proc() {
	size := vk.DeviceSize(MAX_VIEW_MODEL_INSTANCES * size_of(Model_Instance))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		model_renderer.view_buffers[i], model_renderer.view_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				model_renderer.view_memories[i],
				0,
				size,
				{},
				&model_renderer.view_mapped[i],
			),
		)
	}

	model_renderer.view_batches = make([dynamic]Model_Batch, 0, MAX_VIEW_MODEL_INSTANCES)
	model_renderer.view_instances = make([dynamic]Model_Instance, 0, MAX_VIEW_MODEL_INSTANCES)
}

create_model_pipeline :: proc() {
	bindings := model_binding_descriptions()
	attributes := model_attribute_descriptions()

	push := []vk.PushConstantRange {
		{stageFlags = {.VERTEX}, offset = 0, size = size_of(linalg.Matrix4f32)},
	}

	model_renderer.pipeline = build_pipeline(
		{
			name = "models",
			vert_spv = MODEL_VERT_CODE,
			// The map's own fragment shader: a model surface is a world surface
			// that arrived from a file.
			frag_spv = WORLD_FRAG_CODE,
			bindings = bindings[:],
			attributes = attributes[:],
			set_layouts = {descriptors.frame_layout, descriptors.material_layout},
			push_constants = push,
			color_formats = {g.swapchain_format},
			depth_format = g.depth_format,
			samples = g.msaa_samples,
			spec = shadow_spec_constants(),
		},
	)
}

destroy_model_renderer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, model_renderer.view_memories[i])
		destroy_buffer(model_renderer.view_buffers[i], model_renderer.view_memories[i])
	}
	if model_renderer.static_count > 0 {
		destroy_buffer(model_renderer.static_buffer, model_renderer.static_memory)
	}
	delete(model_renderer.static_batches)
	delete(model_renderer.view_batches)
	delete(model_renderer.view_instances)
}

// ------------------------------------------------------------------ building

// A placement is what map_props.odin produces: which mesh, and the transform
// that puts it on the map.
Model_Placement :: struct {
	mesh:  string,
	model: linalg.Matrix4f32,
}

// Uploads the map's props once. Placements that share a mesh are gathered so
// eight identical crates cost one draw rather than eight -- which is also why
// this sorts rather than trusting the caller's order.
build_static_models :: proc(placements: []Model_Placement) {
	if len(placements) == 0 do return

	instances := make([dynamic]Model_Instance, 0, len(placements), context.temp_allocator)
	batches := make([dynamic]Model_Batch, 0, 16)

	used := make([]bool, len(placements), context.temp_allocator)
	for i in 0 ..< len(placements) {
		if used[i] do continue

		first := u32(len(instances))
		count := u32(0)
		for j in i ..< len(placements) {
			if used[j] || placements[j].mesh != placements[i].mesh do continue
			used[j] = true
			append(
				&instances,
				Model_Instance{model = placements[j].model, params = {1, 0, 0, 0}},
			)
			count += 1
		}

		append(
			&batches,
			Model_Batch {
				mesh = find_mesh(placements[i].mesh),
				first_instance = first,
				instance_count = count,
			},
		)
	}

	model_renderer.static_buffer, model_renderer.static_memory = create_device_local_buffer(
		instances[:],
		{.VERTEX_BUFFER},
	)
	model_renderer.static_batches = batches[:]
	model_renderer.static_count = u32(len(instances))

	log.infof("Props: {} placed, {} draws", len(instances), len(batches))
}

model_begin_frame :: proc() {
	clear(&model_renderer.view_batches)
	clear(&model_renderer.view_instances)
}

// Viewmodel geometry for this frame. Never shadowed: it sits centimetres from
// the eye, well inside the first cascade's bias, and would self-shadow into a
// mess.
add_view_model :: proc(mesh_name: string, model: linalg.Matrix4f32) {
	if len(model_renderer.view_instances) >= MAX_VIEW_MODEL_INSTANCES {
		log.panicf("more than {} viewmodel instances", MAX_VIEW_MODEL_INSTANCES)
	}

	append(
		&model_renderer.view_batches,
		Model_Batch {
			mesh = find_mesh(mesh_name),
			first_instance = u32(len(model_renderer.view_instances)),
			instance_count = 1,
		},
	)
	append(&model_renderer.view_instances, Model_Instance{model = model, params = {0, 0, 0, 0}})
}

upload_model_instances :: proc(frame: u32) {
	count := len(model_renderer.view_instances)
	if count == 0 do return

	mem.copy(
		model_renderer.view_mapped[frame],
		raw_data(model_renderer.view_instances),
		count * size_of(Model_Instance),
	)
}

// ------------------------------------------------------------------- drawing

@(private = "file")
draw_batches :: proc(
	cmd: vk.CommandBuffer,
	instance_buffer: vk.Buffer,
	batches: []Model_Batch,
) {
	buffers := []vk.Buffer{mesh_store.vertex_buffer, instance_buffer}
	offsets := []vk.DeviceSize{0, 0}
	vk.CmdBindVertexBuffers(cmd, 0, 2, raw_data(buffers), raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, mesh_store.index_buffer, 0, .UINT32)

	for batch in batches {
		vk.CmdDrawIndexed(
			cmd,
			batch.mesh.index_count,
			batch.instance_count,
			batch.mesh.first_index,
			batch.mesh.base_vertex,
			batch.first_instance,
		)
	}
}

@(private = "file")
push_view_projection :: proc(cmd: vk.CommandBuffer, vp: linalg.Matrix4f32) {
	vp := vp
	vk.CmdPushConstants(
		cmd,
		model_renderer.pipeline.layout,
		{.VERTEX},
		0,
		size_of(linalg.Matrix4f32),
		&vp,
	)
}

// The props. Drawn with the world's view-projection, after the world itself.
record_model_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if model_renderer.static_count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, model_renderer.pipeline.pipeline)
	bind_frame_set(cmd, model_renderer.pipeline.layout, frame)
	bind_material_set(cmd, model_renderer.pipeline.layout)
	push_view_projection(cmd, camera_view_projection())

	draw_batches(cmd, model_renderer.static_buffer, model_renderer.static_batches)
}

// The weapon, on the depth buffer the viewmodel block already cleared.
record_view_model_draws :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if len(model_renderer.view_batches) == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, model_renderer.pipeline.pipeline)
	bind_frame_set(cmd, model_renderer.pipeline.layout, frame)
	bind_material_set(cmd, model_renderer.pipeline.layout)
	push_view_projection(cmd, viewmodel_view_projection())

	draw_batches(cmd, model_renderer.view_buffers[frame], model_renderer.view_batches[:])
}

// Props into a shadow cascade. The pipeline and the cascade push constant are
// set by the caller, which owns the cascade loop.
record_model_shadow_draw :: proc(cmd: vk.CommandBuffer) {
	if model_renderer.static_count == 0 do return
	draw_batches(cmd, model_renderer.static_buffer, model_renderer.static_batches)
}
