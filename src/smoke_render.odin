package main

import "core:mem"
import "protocol"
import vk "vendor:vulkan"

// Volumetric smoke. One instanced box per cloud, and a fragment shader that
// marches the ray from the eye through it, stopping at whatever the opaque pass
// already drew.
//
// Nothing here decides anything. Whether a smoke blocks a sight line is settled
// on the CPU by game/zone.odin, on the server and the client alike; this only
// has to look like the thing that does.
//
// It draws in a rendering block of its own (see record_scene_pass), because it
// samples the depth buffer the opaque pass wrote and an attachment cannot be
// sampled while it is still bound.

MAX_SMOKE_INSTANCES :: protocol.MAX_SNAPSHOT_ZONES

// Overall optical density. Multiplies the shader's noise field, so it is the
// one dial for "how solid does a full cloud read".
SMOKE_DENSITY :: f32(1.35)

Smoke_Instance :: struct {
	sphere: [4]f32, // xyz centre, w radius
	params: [4]f32, // density, seed, unused, unused
}

#assert(size_of(Smoke_Instance) == 32)

Smoke_Vertex :: struct {
	position: [3]f32,
}

Smoke_Renderer :: struct {
	vertex_buffer:     vk.Buffer,
	vertex_memory:     vk.DeviceMemory,
	index_buffer:      vk.Buffer,
	index_memory:      vk.DeviceMemory,
	instance_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	instance_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	instance_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	pipeline:          Pipeline,
	instances:         [MAX_SMOKE_INSTANCES]Smoke_Instance,
	instance_count:    int,
}

smoke_renderer: Smoke_Renderer

// Whether the frame has any smoke at all. record_scene_pass asks before
// splitting itself into three rendering blocks, so a frame without smoke costs
// exactly what it did before this existed.
smoke_active :: proc() -> bool {
	return smoke_renderer.instance_count > 0
}

smoke_binding_descriptions :: proc() -> [2]vk.VertexInputBindingDescription {
	return {
		{binding = 0, stride = size_of(Smoke_Vertex), inputRate = .VERTEX},
		{binding = 1, stride = size_of(Smoke_Instance), inputRate = .INSTANCE},
	}
}

smoke_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = 0},
		{
			location = 1,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Smoke_Instance, sphere)),
		},
		{
			location = 2,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Smoke_Instance, params)),
		},
	}
}

create_smoke_renderer :: proc() {
	// A unit cube, corners at +-0.5. The vertex shader scales it to whatever
	// sphere the instance names.
	verts := [8]Smoke_Vertex {
		{{-0.5, -0.5, -0.5}},
		{{0.5, -0.5, -0.5}},
		{{0.5, 0.5, -0.5}},
		{{-0.5, 0.5, -0.5}},
		{{-0.5, -0.5, 0.5}},
		{{0.5, -0.5, 0.5}},
		{{0.5, 0.5, 0.5}},
		{{-0.5, 0.5, 0.5}},
	}
	indices := [36]u32 {
		0, 1, 2, 0, 2, 3, // -z
		4, 6, 5, 4, 7, 6, // +z
		0, 4, 5, 0, 5, 1, // -y
		3, 2, 6, 3, 6, 7, // +y
		0, 3, 7, 0, 7, 4, // -x
		1, 5, 6, 1, 6, 2, // +x
	}

	smoke_renderer.vertex_buffer, smoke_renderer.vertex_memory = create_device_local_buffer(
		verts[:],
		{.VERTEX_BUFFER},
	)
	smoke_renderer.index_buffer, smoke_renderer.index_memory = create_device_local_buffer(
		indices[:],
		{.INDEX_BUFFER},
	)

	size := vk.DeviceSize(MAX_SMOKE_INSTANCES * size_of(Smoke_Instance))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		smoke_renderer.instance_buffers[i], smoke_renderer.instance_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				smoke_renderer.instance_memories[i],
				0,
				size,
				{},
				&smoke_renderer.instance_mapped[i],
			),
		)
	}
}

smoke_spec_constants :: proc() -> []Spec_Constant {
	@(static) spec: [3]Spec_Constant
	spec = {
		{id = SPEC_SHADOW_CASCADES, value = i32(shadow_cascades())},
		{id = SPEC_SHADOW_PCF, value = i32(settings.shadow_pcf)},
		{id = SPEC_SMOKE_STEPS, value = i32(settings.smoke_steps)},
	}
	return spec[:]
}

create_smoke_pipeline :: proc() {
	bindings := smoke_binding_descriptions()
	attributes := smoke_attribute_descriptions()

	smoke_renderer.pipeline = build_pipeline(
		{
			name = "smoke",
			vert_spv = SMOKE_VERT_CODE,
			frag_spv = SMOKE_FRAG_CODE,
			bindings = bindings[:],
			attributes = attributes[:],
			set_layouts = {descriptors.frame_layout},
			color_formats = {g.swapchain_format},
			samples = g.msaa_samples,
			// No depth attachment in this block at all: the ray stops at the
			// scene depth it samples instead, which is what lets a cloud be
			// entered rather than clipped against.
			depth_test = .Disabled,
			no_depth_write = true,
			blend = .Premultiplied,
			// Front faces get culled, not back ones: standing inside the box
			// would otherwise clip the cloud away entirely, and the back faces
			// are behind the volume either way.
			cull = .Front,
			spec = smoke_spec_constants(),
		},
	)
}

destroy_smoke_renderer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, smoke_renderer.instance_memories[i])
		destroy_buffer(smoke_renderer.instance_buffers[i], smoke_renderer.instance_memories[i])
	}
	destroy_buffer(smoke_renderer.vertex_buffer, smoke_renderer.vertex_memory)
	destroy_buffer(smoke_renderer.index_buffer, smoke_renderer.index_memory)
}

// Built from the zones the snapshot brought, once per frame.
build_smoke_instances :: proc() {
	smoke_renderer.instance_count = 0
	for i in 0 ..< zones.drawn_count {
		z := &zones.drawn[i]
		if z.kind != .Smoke do continue
		if smoke_renderer.instance_count >= MAX_SMOKE_INSTANCES do break

		// The cloud sits on the ground it landed on, so its centre is a radius
		// up -- matching how zone_contains measures from the same point.
		smoke_renderer.instances[smoke_renderer.instance_count] = {
			sphere = {z.position.x, z.position.y, z.position.z + z.radius * 0.6, z.radius},
			// The seed drifts with the zone's own position, so two clouds never
			// churn in step.
			params = {SMOKE_DENSITY, z.position.x * 0.37 + z.position.y * 0.11, 0, 0},
		}
		smoke_renderer.instance_count += 1
	}
}

upload_smoke :: proc(frame: u32) {
	if smoke_renderer.instance_count == 0 do return
	mem.copy(
		smoke_renderer.instance_mapped[frame],
		raw_data(&smoke_renderer.instances),
		smoke_renderer.instance_count * size_of(Smoke_Instance),
	)
}

record_smoke_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if smoke_renderer.instance_count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, smoke_renderer.pipeline.pipeline)
	bind_frame_set(cmd, smoke_renderer.pipeline.layout, frame)

	buffers := [2]vk.Buffer{smoke_renderer.vertex_buffer, smoke_renderer.instance_buffers[frame]}
	offsets := [2]vk.DeviceSize{0, 0}
	vk.CmdBindVertexBuffers(cmd, 0, 2, raw_data(&buffers), raw_data(&offsets))
	vk.CmdBindIndexBuffer(cmd, smoke_renderer.index_buffer, 0, .UINT32)
	vk.CmdDrawIndexed(cmd, 36, u32(smoke_renderer.instance_count), 0, 0, 0)
}
