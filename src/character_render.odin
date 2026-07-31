package main

import "core:log"
import "core:math/linalg"
import "core:mem"
import "game"
import vk "vendor:vulkan"

// Draws the players. One skinned mesh, one instance per pawn, and a block of
// joint matrices per instance that both this pass and the shadow pass read.
//
// The joint matrices live in the frame descriptor set rather than a set of
// their own. They are per-frame data, which is what that set is for, and it is
// also the only place the shadow pass can see them: its pipelines bind set 0
// and nothing else, and a character whose shadow stood in the bind pose while
// the character walked would be worse than no shadow at all.

MAX_CHARACTER_INSTANCES :: game.MAX_PAWNS

// One block of joints per instance, at the engine's joint cap. Sized for the
// worst case rather than the loaded skeleton so the descriptor range is a
// constant: 16 * 80 matrices is 80 KiB a frame, which is not worth a resize.
CHARACTER_JOINT_SLOTS :: MAX_CHARACTER_INSTANCES * MAX_SKELETON_JOINTS

CHARACTER_JOINT_BYTES :: CHARACTER_JOINT_SLOTS * size_of(linalg.Matrix4f32)

// std430-compatible and the layout the instance attributes describe.
Character_Instance :: struct {
	model:           linalg.Matrix4f32,
	joint_base:      u32, // first joint of this instance in the shared block
	material_offset: u32, // added to the vertex material: 0 for T, 2 for CT
	params:          [2]f32, // receives shadow (0/1), rest reserved
}

// 80 bytes of content in 96, for the same reason Model_Instance is: Odin aligns
// a Matrix4f32 to 32 and pads the struct up to a multiple of it.
#assert(size_of(Character_Instance) == 96)
#assert(offset_of(Character_Instance, joint_base) == 64)
#assert(offset_of(Character_Instance, params) == 72)

Character_Renderer :: struct {
	pipeline:          Pipeline,
	instance_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	instance_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	instance_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	joint_buffers:     [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	joint_memories:    [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	joint_mapped:      [MAX_FRAMES_IN_FLIGHT]rawptr,
	instances:         [dynamic]Character_Instance,
	joints:            [dynamic]linalg.Matrix4f32,
}

character_renderer: Character_Renderer

character_binding_descriptions :: proc() -> [2]vk.VertexInputBindingDescription {
	return {
		skin_binding_description(),
		{binding = 1, stride = size_of(Character_Instance), inputRate = .INSTANCE},
	}
}

character_attribute_descriptions :: proc() -> [12]vk.VertexInputAttributeDescription {
	vertex := skin_attribute_descriptions()
	return {
		vertex[0],
		vertex[1],
		vertex[2],
		vertex[3],
		vertex[4],
		vertex[5],
		vertex[6],
		{location = 7, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 0},
		{location = 8, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 16},
		{location = 9, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 32},
		{location = 10, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 48},
		// joint_base and material_offset in one uvec2, params is not read by the
		// depth pass and would be the only thing this attribute list adds.
		{
			location = 11,
			binding = 1,
			format = .R32G32_UINT,
			offset = u32(offset_of(Character_Instance, joint_base)),
		},
	}
}

// The depth pass skins too, so it needs the joints, the weights and the block
// index -- everything but the surface.
character_shadow_attribute_descriptions :: proc() -> [8]vk.VertexInputAttributeDescription {
	vertex := skin_shadow_attribute_descriptions()
	return {
		vertex[0],
		vertex[1],
		vertex[2],
		{location = 3, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 0},
		{location = 4, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 16},
		{location = 5, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 32},
		{location = 6, binding = 1, format = .R32G32B32A32_SFLOAT, offset = 48},
		{
			location = 7,
			binding = 1,
			format = .R32G32_UINT,
			offset = u32(offset_of(Character_Instance, joint_base)),
		},
	}
}

create_character_renderer :: proc() {
	instance_size := vk.DeviceSize(MAX_CHARACTER_INSTANCES * size_of(Character_Instance))
	joint_size := vk.DeviceSize(CHARACTER_JOINT_BYTES)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		character_renderer.instance_buffers[i], character_renderer.instance_memories[i] =
			create_buffer(instance_size, {.VERTEX_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
		vk_check(
			vk.MapMemory(
				g.device,
				character_renderer.instance_memories[i],
				0,
				instance_size,
				{},
				&character_renderer.instance_mapped[i],
			),
		)

		character_renderer.joint_buffers[i], character_renderer.joint_memories[i] = create_buffer(
			joint_size,
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				character_renderer.joint_memories[i],
				0,
				joint_size,
				{},
				&character_renderer.joint_mapped[i],
			),
		)
	}

	character_renderer.instances = make([dynamic]Character_Instance, 0, MAX_CHARACTER_INSTANCES)
	character_renderer.joints = make([dynamic]linalg.Matrix4f32, 0, CHARACTER_JOINT_SLOTS)
}

create_character_pipeline :: proc() {
	bindings := character_binding_descriptions()
	attributes := character_attribute_descriptions()

	push := []vk.PushConstantRange {
		{stageFlags = {.VERTEX}, offset = 0, size = size_of(linalg.Matrix4f32)},
	}

	character_renderer.pipeline = build_pipeline(
		{
			name           = "characters",
			vert_spv       = CHARACTER_VERT_CODE,
			// The map's fragment shader again: a character surface is a world
			// surface that arrived posed.
			frag_spv       = WORLD_FRAG_CODE,
			bindings       = bindings[:],
			attributes     = attributes[:],
			set_layouts    = {descriptors.frame_layout, descriptors.material_layout},
			push_constants = push,
			color_formats  = {g.swapchain_format},
			depth_format   = g.depth_format,
			samples        = g.msaa_samples,
			spec           = shadow_spec_constants(),
		},
	)
}

destroy_character_renderer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, character_renderer.instance_memories[i])
		destroy_buffer(character_renderer.instance_buffers[i], character_renderer.instance_memories[i])
		vk.UnmapMemory(g.device, character_renderer.joint_memories[i])
		destroy_buffer(character_renderer.joint_buffers[i], character_renderer.joint_memories[i])
	}
	delete(character_renderer.instances)
	delete(character_renderer.joints)
}

// ------------------------------------------------------------------ building

character_begin_frame :: proc() {
	clear(&character_renderer.instances)
	clear(&character_renderer.joints)
}

// Reserves this frame's joint block for one character and hands it back to be
// filled. Returning the slice rather than taking a finished pose is what keeps
// build_joint_matrices from writing into a temporary and copying it here.
character_reserve :: proc(
	model: linalg.Matrix4f32,
	team: game.Team,
) -> (
	joints: []linalg.Matrix4f32,
	ok: bool,
) {
	if len(character_renderer.instances) >= MAX_CHARACTER_INSTANCES {
		return nil, false
	}

	base := u32(len(character_renderer.joints))
	count := skeleton_joint_count()
	resize(&character_renderer.joints, int(base) + count)

	append(
		&character_renderer.instances,
		Character_Instance {
			model = model,
			joint_base = base,
			material_offset = team == .CT ? CHARACTER_MATERIAL_STRIDE : 0,
			params = {1, 0},
		},
	)
	return character_renderer.joints[base:][:count], true
}

character_instance_count :: proc() -> u32 {
	return u32(len(character_renderer.instances))
}

upload_character_instances :: proc(frame: u32) {
	count := len(character_renderer.instances)
	if count == 0 do return

	mem.copy(
		character_renderer.instance_mapped[frame],
		raw_data(character_renderer.instances),
		count * size_of(Character_Instance),
	)

	joints := len(character_renderer.joints)
	if joints > CHARACTER_JOINT_SLOTS {
		log.panicf("{} joints exceeds the buffer's {}", joints, CHARACTER_JOINT_SLOTS)
	}
	mem.copy(
		character_renderer.joint_mapped[frame],
		raw_data(character_renderer.joints),
		joints * size_of(linalg.Matrix4f32),
	)
}

// ------------------------------------------------------------------- drawing

@(private = "file")
bind_character_geometry :: proc(cmd: vk.CommandBuffer, frame: u32) {
	buffers := []vk.Buffer{character_skin.vertex_buffer, character_renderer.instance_buffers[frame]}
	offsets := []vk.DeviceSize{0, 0}
	vk.CmdBindVertexBuffers(cmd, 0, 2, raw_data(buffers), raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, character_skin.index_buffer, 0, .UINT32)
}

// Every character in one instanced draw: they share a mesh, and the only thing
// that differs between them is in the instance.
record_character_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	count := character_instance_count()
	if count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, character_renderer.pipeline.pipeline)
	bind_frame_set(cmd, character_renderer.pipeline.layout, frame)
	bind_material_set(cmd, character_renderer.pipeline.layout)
	bind_character_geometry(cmd, frame)

	vp := camera_view_projection()
	vk.CmdPushConstants(
		cmd,
		character_renderer.pipeline.layout,
		{.VERTEX},
		0,
		size_of(linalg.Matrix4f32),
		&vp,
	)
	vk.CmdDrawIndexed(cmd, character_skin.index_count, count, 0, 0, 0)
}

// Into a shadow cascade. The pipeline and the cascade push constant belong to
// the caller, which owns the cascade loop.
record_character_shadow_draw :: proc(cmd: vk.CommandBuffer, frame: u32) {
	count := character_instance_count()
	if count == 0 do return

	bind_character_geometry(cmd, frame)
	vk.CmdDrawIndexed(cmd, character_skin.index_count, count, 0, 0, 0)
}
