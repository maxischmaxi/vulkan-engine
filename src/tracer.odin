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

// How long one point of the path glows. Speed is the weapon's own business
// (game/weapon.odin), and the length follows from the two -- so a fast round
// draws a long dash and a slow one a short one, both on screen for the same
// handful of frames. It doubles as the floor on a streak's life: a shot into a
// wall two metres away has a path shorter than its own dash, so it lives this
// long rather than for the two metres.
TRACER_DWELL :: 0.022 // seconds

// A weapon the table forgot still draws something.
TRACER_MIN_SPEED :: 200.0

// Half width as a fraction of the vertical half tangent of whatever lens is in
// front of it, which makes it a constant thread of pixels -- about 2.8 of them
// across at 1080p -- at one metre and at seventy, scoped and not. A width fixed
// in metres is a wedge instead: fifty pixels at the muzzle through a scope, and
// sub-pixel at the far end of the same sightline.
TRACER_SCREEN_HALF :: 0.0026
// The one metric limit on it, and only as insurance: past this the far end of a
// very long streak is a quad wide enough to fray against the surface it ends on.
// There is deliberately no lower limit -- the width above is a constant count of
// pixels, so it never thins toward nothing, and a floor in metres would only
// bring back the wedge it replaced.
TRACER_MAX_HALF_WIDTH :: 0.10

// The streak stops just short of what the shot hit. Its tip is otherwise
// coplanar with that surface, and a depth test it cannot win eats the last
// centimetres exactly where the eye goes looking for the impact.
TRACER_END_BIAS :: 0.03

Tracer :: struct {
	start:  [3]f32,
	dir:    [3]f32, // unit vector, muzzle toward impact
	length: f32, // muzzle to impact
	speed:  f32, // metres per second, off the weapon table
	streak: f32, // the glowing part: speed * TRACER_DWELL
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

// `speed` is the weapon's tracer_speed; anything at or below zero falls back
// rather than drawing a streak that never moves.
add_tracer :: proc(start, end: [3]f32, speed: f32) {
	span := end - start
	distance := linalg.length(span)
	length := distance - TRACER_END_BIAS
	// Point-blank leaves nothing to draw.
	if length < 0.01 do return

	v := max(speed, TRACER_MIN_SPEED)
	tracer_renderer.tracers[tracer_renderer.next] = {
		start  = start,
		dir    = span / distance,
		length = length,
		speed  = v,
		streak = v * TRACER_DWELL,
		active = true,
	}
	tracer_renderer.next = (tracer_renderer.next + 1) % MAX_TRACERS
}

// Advances every streak and builds the camera-facing quads for this frame.
// Runs after the camera has settled: the expansion below reads its position.
update_tracers :: proc(dt: f32) {
	tracer_renderer.quad_count = 0

	// One lens read for the frame -- every streak is measured through the same
	// eye -- and only the vertical half angle, which no aspect or scope mask
	// changes.
	_, half_h := camera_half_tangents(camera.fov_horizontal)

	for &t in tracer_renderer.tracers {
		if !t.active do continue

		t.head += t.speed * dt
		tail := t.head - t.streak
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
		side = linalg.normalize(side)

		// One width per end, each from its own distance: the quad comes out a
		// trapezoid, and the perspective divide turns it back into a thread of
		// constant thickness.
		head_side := side * tracer_half_width(head_pos, half_h)
		tail_side := side * tracer_half_width(tail_pos, half_h)

		slot := tracer_renderer.quad_count
		tracer_renderer.vertices[slot * 4 + 0] = {tail_pos - tail_side, {0, -1}}
		tracer_renderer.vertices[slot * 4 + 1] = {tail_pos + tail_side, {0, 1}}
		tracer_renderer.vertices[slot * 4 + 2] = {head_pos + head_side, {1, 1}}
		tracer_renderer.vertices[slot * 4 + 3] = {head_pos - head_side, {1, -1}}
		tracer_renderer.quad_count += 1
	}
}

// The metres a point has to be wide to cover the same pixels wherever it sits.
// The rule itself is camera.odin's; this only names the streak's numbers.
@(private = "file")
tracer_half_width :: proc(point: [3]f32, half_h: f32) -> f32 {
	return screen_half_width(point, half_h, TRACER_SCREEN_HALF, TRACER_MAX_HALF_WIDTH)
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
