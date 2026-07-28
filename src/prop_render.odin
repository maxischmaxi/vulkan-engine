package main

import "core:log"
import "core:math/linalg"
import "core:mem"
import "game"
import vk "vendor:vulkan"

// Everything made of coloured blocks: the bots walking the map and the weapon in
// the player's hands. One unit cube, one instance buffer, two draws.
//
// Sharing a renderer between world objects and the viewmodel works because the
// only thing that differs is which view-projection they are drawn with, and that
// is a push constant.

MAX_PROP_INSTANCES :: 512

Prop_Vertex :: struct {
	pos:    [3]f32,
	normal: [3]f32,
}

#assert(size_of(Prop_Vertex) == 24)

// std430-compatible, and the layout the vertex attributes below describe.
Prop_Instance :: struct {
	model:  linalg.Matrix4f32,
	color:  [4]f32,
	params: [4]f32, // roughness, metallic, emissive, receives shadow (0/1)
}

#assert(size_of(Prop_Instance) == 96)
#assert(offset_of(Prop_Instance, color) == 64)
#assert(offset_of(Prop_Instance, params) == 80)

Prop_Renderer :: struct {
	vertex_buffer:     vk.Buffer,
	vertex_memory:     vk.DeviceMemory,
	index_buffer:      vk.Buffer,
	index_memory:      vk.DeviceMemory,
	index_count:       u32,
	instance_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	instance_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	instance_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	pipeline:          Pipeline,
	// World instances occupy the front of the buffer and viewmodel instances the
	// back, so each draw is a range and there is only one buffer to manage.
	world:             [dynamic]Prop_Instance,
	view:              [dynamic]Prop_Instance,
}

prop_renderer: Prop_Renderer

prop_binding_descriptions :: proc() -> [2]vk.VertexInputBindingDescription {
	return {
		{binding = 0, stride = size_of(Prop_Vertex), inputRate = .VERTEX},
		{binding = 1, stride = size_of(Prop_Instance), inputRate = .INSTANCE},
	}
}

// A mat4 attribute is four vec4 locations; there is no wider vertex format.
prop_attribute_descriptions :: proc() -> [8]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Prop_Vertex, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Prop_Vertex, normal)),
		},
		{location = 2, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 0},
		{location = 3, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 16},
		{location = 4, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 32},
		{location = 5, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 48},
		{
			location = 6,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Prop_Instance, color)),
		},
		{
			location = 7,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Prop_Instance, params)),
		},
	}
}

// The depth-only pass reads position and the model matrix and nothing else.
prop_shadow_attribute_descriptions :: proc() -> [5]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Prop_Vertex, pos)),
		},
		{location = 1, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 0},
		{location = 2, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 16},
		{location = 3, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 32},
		{location = 4, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 48},
	}
}

// Unit cube centred on the origin, so a model matrix scales it about its own
// centre. Wound with the same rule bake_world uses -- counter-clockwise seen
// from outside -- so both feed the same culling setting.
@(private = "file")
build_box_mesh :: proc() -> (verts: [24]Prop_Vertex, indices: [36]u32) {
	mn := [3]f32{-0.5, -0.5, -0.5}
	mx := [3]f32{0.5, 0.5, 0.5}

	v := 0
	i := 0
	for face in game.Face {
		basis := game.FACE_BASES[face]

		cube := game.Brush {
			min = mn,
			max = mx,
		}
		origin := game.face_origin(cube, face)
		u_len, v_len := game.face_extent(cube, face)

		corners := [4][3]f32 {
			origin + basis.v_dir * v_len,
			origin + basis.u_dir * u_len + basis.v_dir * v_len,
			origin + basis.u_dir * u_len,
			origin,
		}

		base := u32(v)
		for p in corners {
			verts[v] = {
				pos    = p,
				normal = basis.normal,
			}
			v += 1
		}

		for offset in ([6]u32{0, 1, 2, 0, 2, 3}) {
			indices[i] = base + offset
			i += 1
		}
	}
	return
}

create_prop_renderer :: proc() {
	verts, indices := build_box_mesh()

	prop_renderer.vertex_buffer, prop_renderer.vertex_memory = create_device_local_buffer(
		verts[:],
		{.VERTEX_BUFFER},
	)
	prop_renderer.index_buffer, prop_renderer.index_memory = create_device_local_buffer(
		indices[:],
		{.INDEX_BUFFER},
	)
	prop_renderer.index_count = u32(len(indices))

	// rewritten every frame, so host-visible and permanently mapped
	size := vk.DeviceSize(MAX_PROP_INSTANCES * size_of(Prop_Instance))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		prop_renderer.instance_buffers[i], prop_renderer.instance_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				prop_renderer.instance_memories[i],
				0,
				size,
				{},
				&prop_renderer.instance_mapped[i],
			),
		)
	}

	prop_renderer.world = make([dynamic]Prop_Instance, 0, 64)
	prop_renderer.view = make([dynamic]Prop_Instance, 0, 32)
}

create_prop_pipeline :: proc() {
	bindings := prop_binding_descriptions()
	attributes := prop_attribute_descriptions()

	push := []vk.PushConstantRange {
		{stageFlags = {.VERTEX}, offset = 0, size = size_of(linalg.Matrix4f32)},
	}

	prop_renderer.pipeline = build_pipeline(
		{
			name = "props",
			vert_spv = PROP_VERT_CODE,
			frag_spv = PROP_FRAG_CODE,
			bindings = bindings[:],
			attributes = attributes[:],
			set_layouts = {descriptors.frame_layout},
			push_constants = push,
			color_formats = {g.swapchain_format},
			depth_format = g.depth_format,
			samples = g.msaa_samples,
			spec = shadow_spec_constants(),
		},
	)
}

destroy_prop_renderer :: proc() {

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, prop_renderer.instance_memories[i])
		destroy_buffer(prop_renderer.instance_buffers[i], prop_renderer.instance_memories[i])
	}

	destroy_buffer(prop_renderer.vertex_buffer, prop_renderer.vertex_memory)
	destroy_buffer(prop_renderer.index_buffer, prop_renderer.index_memory)

	delete(prop_renderer.world)
	delete(prop_renderer.view)
}

// ------------------------------------------------------------------ building

// Axis-aligned block: centre and full size in metres.
prop_transform :: proc(center, size: [3]f32) -> linalg.Matrix4f32 {
	m: linalg.Matrix4f32 = 1
	m[0, 0] = size.x
	m[1, 1] = size.y
	m[2, 2] = size.z
	m[0, 3] = center.x
	m[1, 3] = center.y
	m[2, 3] = center.z
	return m
}

// Block oriented along an arbitrary basis -- what the viewmodel needs, since it
// hangs off the camera's axes rather than the world's.
prop_transform_oriented :: proc(
	center, size: [3]f32,
	right, forward, up: [3]f32,
) -> linalg.Matrix4f32 {
	m: linalg.Matrix4f32 = 1

	// columns are the scaled basis vectors: local x runs along right, y along
	// forward, z along up
	x := right * size.x
	y := forward * size.y
	z := up * size.z

	m[0, 0] = x.x; m[0, 1] = y.x; m[0, 2] = z.x; m[0, 3] = center.x
	m[1, 0] = x.y; m[1, 1] = y.y; m[1, 2] = z.y; m[1, 3] = center.y
	m[2, 0] = x.z; m[2, 1] = y.z; m[2, 2] = z.z; m[2, 3] = center.z
	return m
}

prop_begin_frame :: proc() {
	clear(&prop_renderer.world)
	clear(&prop_renderer.view)
}

add_world_prop :: proc(
	model: linalg.Matrix4f32,
	color: [3]f32,
	roughness: f32 = 0.65,
	metallic: f32 = 0,
	emissive: f32 = 0,
) {
	append(
		&prop_renderer.world,
		Prop_Instance {
			model = model,
			color = {color.r, color.g, color.b, 1},
			params = {roughness, metallic, emissive, 1},
		},
	)
}

// Viewmodel blocks never receive cascaded shadows: they sit centimetres from the
// eye, well inside the first cascade's bias, and would self-shadow into a mess.
add_view_prop :: proc(
	model: linalg.Matrix4f32,
	color: [3]f32,
	roughness: f32 = 0.5,
	metallic: f32 = 0,
	emissive: f32 = 0,
) {
	append(
		&prop_renderer.view,
		Prop_Instance {
			model = model,
			color = {color.r, color.g, color.b, 1},
			params = {roughness, metallic, emissive, 0},
		},
	)
}

prop_world_instance_count :: proc() -> u32 {
	return u32(len(prop_renderer.world))
}

// Both groups land in one buffer, world first. Called once the frame's
// instances are complete and before any pass reads them.
upload_prop_instances :: proc(frame: u32) {
	total := len(prop_renderer.world) + len(prop_renderer.view)
	if total == 0 do return

	if total > MAX_PROP_INSTANCES {
		log.panicf("{} prop instances exceeds the buffer's {}", total, MAX_PROP_INSTANCES)
	}

	dst := ([^]Prop_Instance)(prop_renderer.instance_mapped[frame])
	world_count := len(prop_renderer.world)

	if world_count > 0 {
		mem.copy(&dst[0], raw_data(prop_renderer.world), world_count * size_of(Prop_Instance))
	}
	if len(prop_renderer.view) > 0 {
		mem.copy(
			&dst[world_count],
			raw_data(prop_renderer.view),
			len(prop_renderer.view) * size_of(Prop_Instance),
		)
	}
}

// ------------------------------------------------------------------ drawing

@(private = "file")
bind_prop_geometry :: proc(cmd: vk.CommandBuffer, frame: u32) {
	buffers := []vk.Buffer{prop_renderer.vertex_buffer, prop_renderer.instance_buffers[frame]}
	offsets := []vk.DeviceSize{0, 0}
	vk.CmdBindVertexBuffers(cmd, 0, 2, raw_data(buffers), raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, prop_renderer.index_buffer, 0, .UINT32)
}

// The bots. Drawn with the world's view-projection.
record_prop_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	count := u32(len(prop_renderer.world))
	if count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, prop_renderer.pipeline.pipeline)
	bind_frame_set(cmd, prop_renderer.pipeline.layout, frame)
	bind_prop_geometry(cmd, frame)

	vp := camera_view_projection()
	vk.CmdPushConstants(
		cmd,
		prop_renderer.pipeline.layout,
		{.VERTEX},
		0,
		size_of(linalg.Matrix4f32),
		&vp,
	)
	vk.CmdDrawIndexed(cmd, prop_renderer.index_count, count, 0, 0, 0)
}

// Instanced boxes into a shadow cascade. The pipeline and push constant are set
// up by the caller, which owns the cascade loop.
record_prop_shadow_draw :: proc(cmd: vk.CommandBuffer, frame: u32) {
	count := u32(len(prop_renderer.world))
	if count == 0 do return

	bind_prop_geometry(cmd, frame)
	vk.CmdDrawIndexed(cmd, prop_renderer.index_count, count, 0, 0, 0)
}

prop_view_instance_count :: proc() -> u32 {
	return u32(len(prop_renderer.view))
}

// What is left of the viewmodel that is still made of blocks -- the muzzle
// flash. Its own projection; the depth buffer was cleared by the caller, which
// owns the whole viewmodel block.
record_viewmodel_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	count := u32(len(prop_renderer.view))
	if count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, prop_renderer.pipeline.pipeline)
	bind_frame_set(cmd, prop_renderer.pipeline.layout, frame)
	bind_prop_geometry(cmd, frame)

	vp := viewmodel_view_projection()
	vk.CmdPushConstants(
		cmd,
		prop_renderer.pipeline.layout,
		{.VERTEX},
		0,
		size_of(linalg.Matrix4f32),
		&vp,
	)
	// world instances sit in front of these in the buffer
	vk.CmdDrawIndexed(cmd, prop_renderer.index_count, count, 0, 0, u32(len(prop_renderer.world)))
}

// Wipes depth for the whole viewport so the weapon is drawn onto a clean slate.
// This is how Source keeps a viewmodel out of walls: not by pushing the near
// plane around, but by giving the weapon its own depth range. Self-occlusion
// within the weapon still works, which a plain depth_compare = ALWAYS would lose.
clear_viewmodel_depth :: proc(cmd: vk.CommandBuffer) {
	// 0 is the far plane under reversed-Z, the same value the pass began with
	attachment := vk.ClearAttachment {
		aspectMask = {.DEPTH},
		clearValue = {depthStencil = {depth = 0.0}},
	}
	// The scene's extent, not the window's: under a render scale below 1 those
	// differ, and a clear rect larger than the rendering area is illegal.
	rect := vk.ClearRect {
		rect = {offset = {0, 0}, extent = scene_extent()},
		baseArrayLayer = 0,
		layerCount = 1,
	}
	vk.CmdClearAttachments(cmd, 1, &attachment, 1, &rect)
}
