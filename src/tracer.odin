package main

import "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"

// Tracers: the streak a shot draws through the air. Purely cosmetic -- the hit
// was decided the moment the trigger fell; this flies the visible story of it
// from the muzzle to that point at a finite speed, so a spray can be read in
// the air as well as on the wall.
//
// A fixed pool like the decals, but rebuilt every frame instead of on change:
// a tracer moves every frame it exists and the quads face the camera, so
// yesterday's vertices are never worth keeping.

MAX_TRACERS :: 64

// Fast enough to read as gunfire, slow enough to be seen travelling: a long
// dust2 sightline (~70 m) takes about a quarter of a second, and even a shot
// into a close wall lives for a few frames.
TRACER_SPEED :: 250.0 // metres per second

// The glowing part of the flight. Much shorter than any sightline, so the
// streak is a moving dash rather than a standing beam.
TRACER_LENGTH :: 4.0

TRACER_HALF_WIDTH :: 0.02

Tracer :: struct {
	start:  [3]f32,
	dir:    [3]f32, // unit vector, muzzle toward impact
	length: f32, // muzzle to impact
	head:   f32, // metres the head has flown so far
	active: bool,
}

Tracer_Vertex :: struct {
	pos:   [3]f32,
	local: [2]f32, // x runs 0..1 tail to head, y -1..1 across the streak
}

#assert(size_of(Tracer_Vertex) == 20)

Tracer_Renderer :: struct {
	vertex_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	vertex_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	vertex_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	index_buffer:    vk.Buffer,
	index_memory:    vk.DeviceMemory,
	pipeline:        Pipeline,
	tracers:         [MAX_TRACERS]Tracer,
	next:            int, // ring cursor; anything it overwrites has had its run
	vertices:        [MAX_TRACERS * 4]Tracer_Vertex,
	quad_count:      int, // quads built for the current frame
}

tracer_renderer: Tracer_Renderer

tracer_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Tracer_Vertex), inputRate = .VERTEX}
}

tracer_attribute_descriptions :: proc() -> [2]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Tracer_Vertex, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Tracer_Vertex, local)),
		},
	}
}

create_tracer_renderer :: proc() {
	indices := make([]u32, MAX_TRACERS * 6, context.temp_allocator)
	for i in 0 ..< MAX_TRACERS {
		base := u32(i * 4)
		indices[i * 6 + 0] = base
		indices[i * 6 + 1] = base + 1
		indices[i * 6 + 2] = base + 2
		indices[i * 6 + 3] = base
		indices[i * 6 + 4] = base + 2
		indices[i * 6 + 5] = base + 3
	}
	tracer_renderer.index_buffer, tracer_renderer.index_memory = create_device_local_buffer(
		indices,
		{.INDEX_BUFFER},
	)

	size := vk.DeviceSize(len(tracer_renderer.vertices) * size_of(Tracer_Vertex))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		tracer_renderer.vertex_buffers[i], tracer_renderer.vertex_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				tracer_renderer.vertex_memories[i],
				0,
				size,
				{},
				&tracer_renderer.vertex_mapped[i],
			),
		)
	}
}

create_tracer_pipeline :: proc() {
	bindings := []vk.VertexInputBindingDescription{tracer_binding_description()}
	attributes := tracer_attribute_descriptions()

	tracer_renderer.pipeline = build_pipeline(
		{
			name           = "tracers",
			vert_spv       = TRACER_VERT_CODE,
			frag_spv       = TRACER_FRAG_CODE,
			bindings       = bindings,
			attributes     = attributes[:],
			set_layouts    = {descriptors.frame_layout},
			color_formats  = {g.swapchain_format},
			depth_format   = g.depth_format,
			samples        = g.msaa_samples,
			// Behind a wall means invisible, but the streak itself occludes
			// nothing: test depth, never write it.
			depth_test     = .Nearer,
			no_depth_write = true,
			blend          = .Additive,
			// a camera-facing quad has no meaningful winding
			cull           = .None,
			spec           = shadow_spec_constants(),
		},
	)
}

destroy_tracer_renderer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, tracer_renderer.vertex_memories[i])
		destroy_buffer(tracer_renderer.vertex_buffers[i], tracer_renderer.vertex_memories[i])
	}
	destroy_buffer(tracer_renderer.index_buffer, tracer_renderer.index_memory)
}

add_tracer :: proc(start, end: [3]f32) {
	span := end - start
	length := linalg.length(span)
	// Point-blank leaves nothing to draw.
	if length < 0.01 do return

	tracer_renderer.tracers[tracer_renderer.next] = {
		start  = start,
		dir    = span / length,
		length = length,
		active = true,
	}
	tracer_renderer.next = (tracer_renderer.next + 1) % MAX_TRACERS
}

// Advances every streak and builds the camera-facing quads for this frame.
// Runs after the camera has settled: the expansion below reads its position.
update_tracers :: proc(dt: f32) {
	tracer_renderer.quad_count = 0

	for &t in tracer_renderer.tracers {
		if !t.active do continue

		t.head += TRACER_SPEED * dt
		tail := t.head - TRACER_LENGTH
		if tail >= t.length {
			t.active = false
			continue
		}

		head_pos := t.start + t.dir * min(t.head, t.length)
		tail_pos := t.start + t.dir * max(tail, 0)

		// Near-degenerate when the streak points straight at the eye; the
		// muzzle offset keeps it from ever quite getting there, but the guard
		// costs nothing.
		mid := (head_pos + tail_pos) * 0.5
		side := linalg.cross(t.dir, camera.position - mid)
		if linalg.dot(side, side) < 1e-8 do continue
		side = linalg.normalize(side) * TRACER_HALF_WIDTH

		slot := tracer_renderer.quad_count
		tracer_renderer.vertices[slot * 4 + 0] = {tail_pos - side, {0, -1}}
		tracer_renderer.vertices[slot * 4 + 1] = {tail_pos + side, {0, 1}}
		tracer_renderer.vertices[slot * 4 + 2] = {head_pos + side, {1, 1}}
		tracer_renderer.vertices[slot * 4 + 3] = {head_pos - side, {1, -1}}
		tracer_renderer.quad_count += 1
	}
}

// Every frame with tracers in flight uploads, unlike the decals' dirty flag:
// the vertices are new whenever there is anything to draw at all.
upload_tracers :: proc(frame: u32) {
	if tracer_renderer.quad_count == 0 do return

	mem.copy(
		tracer_renderer.vertex_mapped[frame],
		raw_data(&tracer_renderer.vertices),
		tracer_renderer.quad_count * 4 * size_of(Tracer_Vertex),
	)
}

record_tracer_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if tracer_renderer.quad_count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, tracer_renderer.pipeline.pipeline)
	bind_frame_set(cmd, tracer_renderer.pipeline.layout, frame)

	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &tracer_renderer.vertex_buffers[frame], raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, tracer_renderer.index_buffer, 0, .UINT32)

	vk.CmdDrawIndexed(cmd, u32(tracer_renderer.quad_count * 6), 1, 0, 0, 0)
}
