package main

import "core:slice"
import "game"
import "physics"
import vk "vendor:vulkan"

// Front-to-back draw order for the world.
//
// The map is one draw call, and the index buffer used to hold it in authoring
// order -- with the ground at index zero, so the largest surface in the game
// was drawn first and everything else was shaded on top of it. Sorting the
// brushes by distance to the camera each frame lets early-z reject the far side
// of the map instead of shading it, for the price of rewriting ~23 KB of
// indices into a per-frame buffer. Still one draw call.
//
// The static index buffer stays: the shadow pass keeps using it, because its
// notion of "front" is the sun's, not the camera's.

Brush_Range :: struct {
	first:  u32, // into world_indices
	count:  u32,
	bounds: physics.Aabb,
}

World_Order :: struct {
	ranges:   []Brush_Range,
	entries:  []Sort_Entry, // scratch, reused every frame
	buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
}

Sort_Entry :: struct {
	key:   f32, // squared distance from the camera to the brush
	first: u32,
	count: u32,
}

world_order: World_Order

// Groups the clipped faces by brush and records each brush's index range.
// Mutates the face order; emit_face_quad must run over the same order or the
// ranges point at the wrong triangles.
build_world_order :: proc(faces: []game.Baked_Face, brushes: []game.Brush) {
	slice.sort_by(faces, proc(a, b: game.Baked_Face) -> bool {
		return a.brush < b.brush
	})

	ranges := make([dynamic]Brush_Range)
	i := 0
	for i < len(faces) {
		j := i
		for j < len(faces) && faces[j].brush == faces[i].brush do j += 1

		b := brushes[faces[i].brush]
		append(
			&ranges,
			Brush_Range {
				first = u32(i * 6),
				count = u32((j - i) * 6),
				bounds = {min = b.min, max = b.max},
			},
		)
		i = j
	}
	world_order.ranges = ranges[:]
	world_order.entries = make([]Sort_Entry, len(world_order.ranges))
}

create_world_order_buffers :: proc() {
	size := vk.DeviceSize(len(world_indices) * size_of(u32))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		world_order.buffers[i], world_order.memories[i] = create_buffer(
			size,
			{.INDEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(g.device, world_order.memories[i], 0, size, {}, &world_order.mapped[i]),
		)
	}
}

destroy_world_order :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, world_order.memories[i])
		destroy_buffer(world_order.buffers[i], world_order.memories[i])
	}
	delete(world_order.entries)
	delete(world_order.ranges)
}

// Distance from the camera to the nearest point of the box, not to its centre:
// the ground brush spans the whole map, and its centre would sort it behind
// everything the player is standing right on top of.
@(private = "file")
distance_key :: proc(bounds: physics.Aabb, eye: [3]f32) -> f32 {
	d: f32
	for axis in 0 ..< 3 {
		v := clamp(eye[axis], bounds.min[axis], bounds.max[axis]) - eye[axis]
		d += v * v
	}
	return d
}

// Sorts the brush ranges for this camera position and writes the reordered
// indices into this frame's buffer.
upload_world_order :: proc(frame: u32) {
	for r, i in world_order.ranges {
		world_order.entries[i] = {
			key   = distance_key(r.bounds, camera.position),
			first = r.first,
			count = r.count,
		}
	}
	slice.sort_by(world_order.entries, proc(a, b: Sort_Entry) -> bool {
		return a.key < b.key
	})

	dst := ([^]u32)(world_order.mapped[frame])
	cursor := 0
	for e in world_order.entries {
		copy(dst[cursor:cursor + int(e.count)], world_indices[e.first:e.first + e.count])
		cursor += int(e.count)
	}
}

// The world's vertex buffer with this frame's sorted indices.
bind_world_sorted :: proc(cmd: vk.CommandBuffer, frame: u32) {
	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &world_renderer.vertex_buffer, raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, world_order.buffers[frame], 0, .UINT32)
}
