package main

import "core:math/linalg"
import "core:mem"
import "game"
import vk "vendor:vulkan"

// The throw preview: the white line a wound-up grenade would fly, and the
// circle where it would first touch something.
//
// Where it goes is game/throw_arc.odin's answer, deliberately -- the line is a
// promise the server has to keep, so it is flown with the simulation's own step
// and the same throw_velocity both ends call. This file only turns that answer
// into geometry.
//
// Rebuilt every frame like the tracers rather than cached: the aim moves, the
// wind-up grows, and the quads face a camera that is never still.

// Seconds of wind-up before the line appears. Long enough that a quick lob
// never paints one, short enough that a player lining something up has it well
// before they are ready to let go.
THROW_ARC_DELAY :: f32(0.5)
THROW_ARC_FADE :: f32(0.15)

// Half width as a fraction of the vertical half tangent, the same rule the
// tracers are drawn by (screen_half_width) -- about 2.2 pixels across at 1080p
// at any distance and through any lens.
ARC_SCREEN_HALF :: 0.0021
ARC_MAX_HALF_WIDTH :: 0.06

// The impact circle, metres. Fixed in the world rather than on the screen: it
// marks a spot on a surface, and a spot that kept its pixel size would lie
// about how big the area of effect is from far away.
ARC_RING_RADIUS :: f32(0.45)
ARC_RING_LIFT :: f32(0.01) // off the surface, so it is not co-planar with it

// One quad per arc step plus the ring.
MAX_ARC_QUADS :: game.ARC_MAX_POINTS

Arc_Vertex :: struct {
	pos:    [3]f32,
	local:  [2]f32, // ribbon: x metres along the arc, y -1..1 across; ring: -1..1 both
	params: [2]f32, // shape (0 ribbon, 1 ring), opacity
}

#assert(size_of(Arc_Vertex) == 28)

Arc_Renderer :: struct {
	vertex_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	vertex_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	vertex_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	index_buffer:    vk.Buffer,
	index_memory:    vk.DeviceMemory,
	pipeline:        Pipeline,
	vertices:        [MAX_ARC_QUADS * 4]Arc_Vertex,
	quad_count:      int,
	// Eased visibility, so the line arrives and leaves rather than blinking.
	fade:            f32,
}

arc_renderer: Arc_Renderer

arc_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Arc_Vertex), inputRate = .VERTEX}
}

arc_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Arc_Vertex, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Arc_Vertex, local)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Arc_Vertex, params)),
		},
	}
}

create_arc_renderer :: proc() {
	indices := make([]u32, MAX_ARC_QUADS * 6, context.temp_allocator)
	for i in 0 ..< MAX_ARC_QUADS {
		base := u32(i * 4)
		indices[i * 6 + 0] = base
		indices[i * 6 + 1] = base + 1
		indices[i * 6 + 2] = base + 2
		indices[i * 6 + 3] = base
		indices[i * 6 + 4] = base + 2
		indices[i * 6 + 5] = base + 3
	}
	arc_renderer.index_buffer, arc_renderer.index_memory = create_device_local_buffer(
		indices,
		{.INDEX_BUFFER},
	)

	size := vk.DeviceSize(len(arc_renderer.vertices) * size_of(Arc_Vertex))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		arc_renderer.vertex_buffers[i], arc_renderer.vertex_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				arc_renderer.vertex_memories[i],
				0,
				size,
				{},
				&arc_renderer.vertex_mapped[i],
			),
		)
	}
}

create_arc_pipeline :: proc() {
	bindings := []vk.VertexInputBindingDescription{arc_binding_description()}
	attributes := arc_attribute_descriptions()

	arc_renderer.pipeline = build_pipeline(
		{
			name           = "throw arc",
			vert_spv       = ARC_VERT_CODE,
			frag_spv       = ARC_FRAG_CODE,
			bindings       = bindings,
			attributes     = attributes[:],
			set_layouts    = {descriptors.frame_layout},
			color_formats  = {g.swapchain_format},
			depth_format   = g.depth_format,
			samples        = g.msaa_samples,
			// Behind a wall means invisible: the line has to stop where the
			// sight line does, or it would show what is round the corner.
			depth_test     = .Nearer,
			no_depth_write = true,
			blend          = .Alpha,
			// camera-facing quads have no meaningful winding
			cull           = .None,
			spec           = shadow_spec_constants(),
		},
	)
}

destroy_arc_renderer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, arc_renderer.vertex_memories[i])
		destroy_buffer(arc_renderer.vertex_buffers[i], arc_renderer.vertex_memories[i])
	}
	destroy_buffer(arc_renderer.index_buffer, arc_renderer.index_memory)
}

// Whether the preview should be on screen at all. The delay is measured in the
// wind-up's own ticks rather than in seconds off the frame clock, so it lands at
// the same point of the charge on every machine.
@(private = "file")
arc_wanted :: proc() -> bool {
	if !scene_playing() do return false
	if !player.alive do return false
	// The bomb is placed, not thrown, and a weapon has no arc at all.
	if hand_view.grenade < 0 do return false

	return hand_view.wind.charge >= u8(THROW_ARC_DELAY * game.TICK_RATE)
}

// Runs once per frame after the camera has settled -- the quads are measured
// through the eye they will be seen with.
update_throw_arc :: proc(dt: f32) {
	arc_renderer.quad_count = 0

	wanted := arc_wanted()
	arc_renderer.fade = ui_approach(arc_renderer.fade, wanted ? 1 : 0, dt, 1 / THROW_ARC_FADE)
	if arc_renderer.fade <= 0.01 do return

	kind := game.Grenade_Kind(max(hand_view.grenade, 0))
	origin, velocity := hand_throw_ray()
	arc := game.predict_throw_arc(&gs.grid, origin, velocity, game.GRENADES[kind].radius)
	if arc.count < 2 do return

	_, half_h := camera_half_tangents(camera.fov_horizontal)
	opacity := arc_renderer.fade

	travelled := f32(0)
	for i in 0 ..< arc.count - 1 {
		from := arc.points[i]
		to := arc.points[i + 1]
		span := to - from
		length := linalg.length(span)
		if length < 1e-5 do continue

		direction := span / length

		// Which way the ribbon opens out: perpendicular to both the segment and
		// the line to the eye.
		//
		// Both operands normalised, so the cross product's LENGTH is the sine of
		// the angle between them -- and that is the number this has to be judged
		// on. Where a segment points nearly at the eye the direction of the
		// result is numerically meaningless and flips between frames, which
		// spins the ribbon on its own axis. The first metres out of the hand are
		// exactly that case, because a throw goes where the player is looking.
		//
		// A guard against a near-zero length instead (the obvious version) does
		// not catch it: the vector is still a good deal longer than any epsilon
		// while its direction is already useless. Dropping these segments is
		// free -- they cover a pixel or two end-on, and the near fade in the
		// shader has them at no opacity anyway.
		mid := (from + to) * 0.5
		to_eye := camera.position - mid
		eye_distance := linalg.length(to_eye)
		if eye_distance < 1e-4 {
			travelled += length
			continue
		}
		side := linalg.cross(direction, to_eye / eye_distance)
		if linalg.length(side) < 0.1 { 	// about 6 degrees off the sight line
			travelled += length
			continue
		}
		side = linalg.normalize(side)

		// One width per end, each from its own distance: the quad comes out a
		// trapezoid, and the perspective divide turns it back into a thread of
		// constant thickness.
		from_side := side * screen_half_width(from, half_h, ARC_SCREEN_HALF, ARC_MAX_HALF_WIDTH)
		to_side := side * screen_half_width(to, half_h, ARC_SCREEN_HALF, ARC_MAX_HALF_WIDTH)

		slot := arc_renderer.quad_count
		if slot >= MAX_ARC_QUADS - 1 do break // the ring keeps the last slot
		arc_renderer.vertices[slot * 4 + 0] = {from - from_side, {travelled, -1}, {0, opacity}}
		arc_renderer.vertices[slot * 4 + 1] = {from + from_side, {travelled, 1}, {0, opacity}}
		travelled += length
		arc_renderer.vertices[slot * 4 + 2] = {to + to_side, {travelled, 1}, {0, opacity}}
		arc_renderer.vertices[slot * 4 + 3] = {to - to_side, {travelled, -1}, {0, opacity}}
		arc_renderer.quad_count += 1
	}

	if !arc.hit do return
	add_arc_ring(arc.hit_point, arc.hit_normal, opacity)
}

@(private = "file")
add_arc_ring :: proc(point, normal: [3]f32, opacity: f32) {
	if arc_renderer.quad_count >= MAX_ARC_QUADS do return

	// The decals' basis, for the same job: a quad lying flat on the surface it
	// marks, whichever way that surface faces.
	right, up := surface_basis(normal)
	centre := point + normal * ARC_RING_LIFT

	slot := arc_renderer.quad_count
	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for c, i in corners {
		arc_renderer.vertices[slot * 4 + i] = {
			pos    = centre + right * (c.x * ARC_RING_RADIUS) + up * (c.y * ARC_RING_RADIUS),
			local  = c,
			params = {1, opacity},
		}
	}
	arc_renderer.quad_count += 1
}

upload_throw_arc :: proc(frame: u32) {
	if arc_renderer.quad_count == 0 do return

	mem.copy(
		arc_renderer.vertex_mapped[frame],
		raw_data(&arc_renderer.vertices),
		arc_renderer.quad_count * 4 * size_of(Arc_Vertex),
	)
}

record_arc_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if arc_renderer.quad_count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, arc_renderer.pipeline.pipeline)
	bind_frame_set(cmd, arc_renderer.pipeline.layout, frame)

	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &arc_renderer.vertex_buffers[frame], raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, arc_renderer.index_buffer, 0, .UINT32)

	vk.CmdDrawIndexed(cmd, u32(arc_renderer.quad_count * 6), 1, 0, 0, 0)
}
