package physics

import "core:math"

// Uniform broadphase grid over a static set of boxes.
//
// The map is a hundred metres of boxes but a body only ever touches the few
// around it, so every collision query walking the whole array is work thrown
// away. Cells partition x and y only: the map is far wider than it is tall, and
// a 2D grid cannot be starved by a room stacked over a tunnel the way a z-sliced
// one can.
//
// A box whose footprint covers many cells would be listed in every one of them
// and returned by every query near it anyway, so past a threshold it goes on an
// always-checked list instead. The ground slab under the whole map is the case
// this exists for.
//
// Queries return a superset of what a linear scan would find and the narrow
// phase re-tests everything, so the grid can only ever cost correctness by
// *missing* a box -- which is what grid_test pins against brute force.

// Room-sized: small enough that a query rarely sees more than a handful of
// boxes, large enough that a moving body stays within one or two cells.
GRID_CELL :: f32(4.0)

// Footprint in cells past which a box is always checked instead of listed.
GRID_OVERSIZED_CELLS :: 16

Grid :: struct {
	boxes:     []Aabb, // borrowed, never freed here; entries index into it
	origin:    [2]f32,
	dims:      [2]int,
	cell:      f32,
	starts:    []i32, // CSR: cell c owns entries[starts[c] ..< starts[c+1]]
	entries:   []i32,
	oversized: []i32,
	// Dedup for queries: a box listed in several visited cells is reported once.
	// Mutable query state, which is why every query takes ^Grid.
	stamp:     []u32,
	gen:       u32,
	scratch:   [dynamic]Aabb, // the last candidate query's result lives here
}

grid_build :: proc(boxes: []Aabb, cell: f32 = GRID_CELL, allocator := context.allocator) -> Grid {
	g := Grid {
		boxes = boxes,
		cell  = cell,
		dims  = {1, 1},
	}

	if len(boxes) > 0 {
		lo := [2]f32{boxes[0].min.x, boxes[0].min.y}
		hi := [2]f32{boxes[0].max.x, boxes[0].max.y}
		for b in boxes {
			lo.x = min(lo.x, b.min.x)
			lo.y = min(lo.y, b.min.y)
			hi.x = max(hi.x, b.max.x)
			hi.y = max(hi.y, b.max.y)
		}
		g.origin = lo
		g.dims.x = max(int(math.ceil((hi.x - lo.x) / cell)), 1)
		g.dims.y = max(int(math.ceil((hi.y - lo.y) / cell)), 1)
	}

	cells := g.dims.x * g.dims.y
	counts := make([]i32, cells, context.temp_allocator)

	oversized := make([dynamic]i32, allocator)
	for b, i in boxes {
		cx0, cx1 := cell_span(&g, b.min.x, b.max.x, 0)
		cy0, cy1 := cell_span(&g, b.min.y, b.max.y, 1)
		if (cx1 - cx0 + 1) * (cy1 - cy0 + 1) > GRID_OVERSIZED_CELLS {
			append(&oversized, i32(i))
			continue
		}
		for cy in cy0 ..= cy1 {
			for cx in cx0 ..= cx1 {
				counts[cy * g.dims.x + cx] += 1
			}
		}
	}
	g.oversized = oversized[:]

	g.starts = make([]i32, cells + 1, allocator)
	total: i32
	for c in 0 ..< cells {
		g.starts[c] = total
		total += counts[c]
	}
	g.starts[cells] = total

	// second pass fills; counts becomes the per-cell write cursor
	for c in 0 ..< cells do counts[c] = 0
	g.entries = make([]i32, total, allocator)
	outer: for b, i in boxes {
		for idx in g.oversized {
			if idx == i32(i) do continue outer
		}
		cx0, cx1 := cell_span(&g, b.min.x, b.max.x, 0)
		cy0, cy1 := cell_span(&g, b.min.y, b.max.y, 1)
		for cy in cy0 ..= cy1 {
			for cx in cx0 ..= cx1 {
				c := cy * g.dims.x + cx
				g.entries[g.starts[c] + counts[c]] = i32(i)
				counts[c] += 1
			}
		}
	}

	g.stamp = make([]u32, len(boxes), allocator)
	g.scratch = make([dynamic]Aabb, 0, 32, allocator)
	return g
}

grid_destroy :: proc(g: ^Grid) {
	delete(g.starts)
	delete(g.entries)
	delete(g.oversized)
	delete(g.stamp)
	delete(g.scratch)
	g^ = {}
}

// Which cells [lo, hi] touches on one axis. Everything outside the grid clamps
// onto the border cells: that can only add candidates, never lose one.
@(private = "file")
cell_span :: proc(g: ^Grid, lo, hi: f32, axis: int) -> (a, b: int) {
	a = clamp(int((lo - g.origin[axis]) / g.cell), 0, g.dims[axis] - 1)
	b = clamp(int((hi - g.origin[axis]) / g.cell), 0, g.dims[axis] - 1)
	return
}

@(private = "file")
next_gen :: proc(g: ^Grid) {
	g.gen += 1
	if g.gen == 0 { 	// wrapped: stale stamps could collide, so clear them
		for &s in g.stamp do s = 0
		g.gen = 1
	}
}

// Every box that could overlap `bounds`, each once. The slice points into the
// grid's scratch buffer and is valid until the next query.
grid_candidates :: proc(g: ^Grid, bounds: Aabb) -> []Aabb {
	clear(&g.scratch)
	next_gen(g)

	for idx in g.oversized {
		append(&g.scratch, g.boxes[idx])
	}

	cx0, cx1 := cell_span(g, bounds.min.x, bounds.max.x, 0)
	cy0, cy1 := cell_span(g, bounds.min.y, bounds.max.y, 1)
	for cy in cy0 ..= cy1 {
		for cx in cx0 ..= cx1 {
			c := cy * g.dims.x + cx
			for k in g.starts[c] ..< g.starts[c + 1] {
				idx := g.entries[k]
				if g.stamp[idx] == g.gen do continue
				g.stamp[idx] = g.gen
				append(&g.scratch, g.boxes[idx])
			}
		}
	}
	return g.scratch[:]
}

grid_overlaps_any :: proc(g: ^Grid, box: Aabb) -> bool {
	return overlaps_any(box, grid_candidates(g, box))
}

// The wrappers below exist so the swept bounds are computed next to the moves
// they have to cover. Each hands a candidate superset to the untouched narrow
// phase, so behaviour is identical to passing every box -- just cheaper.

grid_step_move :: proc(body: ^Body, g: ^Grid, dx, dy: f32) -> (blocked_x, blocked_y: bool) {
	// the flat move both ways, plus the step-up retry's headroom
	bounds := body_aabb(body^)
	bounds.min.x -= abs(dx)
	bounds.max.x += abs(dx)
	bounds.min.y -= abs(dy)
	bounds.max.y += abs(dy)
	bounds.max.z += body.step
	return step_move(body, grid_candidates(g, expand(bounds, 0.001)), dx, dy)
}

grid_apply_gravity :: proc(body: ^Body, g: ^Grid, gravity, dt: f32) {
	// the vertical distance the move will actually use, after this tick's pull
	dz := abs((body.velocity.z - gravity * dt) * dt)
	bounds := body_aabb(body^)
	bounds.min.z -= dz
	bounds.max.z += dz
	apply_gravity(body, grid_candidates(g, expand(bounds, 0.001)), gravity, dt)
}

grid_stand_hull :: proc(
	body: ^Body,
	g: ^Grid,
	standing_height: f32,
) -> (
	feet_moved: f32,
	ok: bool,
) {
	bounds := body_aabb(body^)
	grow := standing_height - body.height
	if grow > 0 {
		// grown into the space above on the ground, feet dropped when airborne
		bounds.max.z += grow
		bounds.min.z -= grow * 0.5
	}
	return stand_hull(body, grid_candidates(g, expand(bounds, 0.001)), standing_height)
}

// Nearest hit along the ray, walking only the cells the ray passes through.
// Same result as ray_scene over every box; hit.index refers into grid.boxes.
grid_raycast :: proc(g: ^Grid, origin, dir: [3]f32, max_t: f32) -> (best: Ray_Hit, ok: bool) {
	next_gen(g)
	limit := max_t

	for idx in g.oversized {
		ray_test_box(g, idx, origin, dir, &limit, &best, &ok)
	}

	// Clip the ray's 2D projection to the grid rectangle. Every non-oversized box
	// lies inside it, so a ray that never enters can stop at the oversized list.
	t0: f32 = 0
	t1 := max_t
	for axis in 0 ..< 2 {
		lo := g.origin[axis]
		hi := g.origin[axis] + f32(g.dims[axis]) * g.cell
		if abs(dir[axis]) < PARALLEL_EPSILON {
			if origin[axis] < lo || origin[axis] > hi do return best, ok
			continue
		}
		inv := 1 / dir[axis]
		ta := (lo - origin[axis]) * inv
		tb := (hi - origin[axis]) * inv
		if ta > tb do ta, tb = tb, ta
		t0 = max(t0, ta)
		t1 = min(t1, tb)
	}
	if t0 > t1 do return best, ok

	// standard 2D DDA from the entry point
	cx := clamp(int((origin.x + dir.x * t0 - g.origin.x) / g.cell), 0, g.dims.x - 1)
	cy := clamp(int((origin.y + dir.y * t0 - g.origin.y) / g.cell), 0, g.dims.y - 1)

	step_x, step_y: int
	t_max := [2]f32{max(f32), max(f32)}
	t_delta := [2]f32{max(f32), max(f32)}
	if abs(dir.x) >= PARALLEL_EPSILON {
		inv := 1 / dir.x
		step_x = dir.x > 0 ? 1 : -1
		edge := g.origin.x + f32(cx + (dir.x > 0 ? 1 : 0)) * g.cell
		t_max.x = (edge - origin.x) * inv
		t_delta.x = g.cell * abs(inv)
	}
	if abs(dir.y) >= PARALLEL_EPSILON {
		inv := 1 / dir.y
		step_y = dir.y > 0 ? 1 : -1
		edge := g.origin.y + f32(cy + (dir.y > 0 ? 1 : 0)) * g.cell
		t_max.y = (edge - origin.y) * inv
		t_delta.y = g.cell * abs(inv)
	}

	for {
		c := cy * g.dims.x + cx
		for k in g.starts[c] ..< g.starts[c + 1] {
			ray_test_box(g, g.entries[k], origin, dir, &limit, &best, &ok)
		}

		t_next := min(t_max.x, t_max.y)
		// A hit closer than the next cell's entry cannot be beaten: any unseen
		// box is only reachable through cells the ray enters at or after t_next.
		if ok && best.t <= t_next do break
		if t_next > t1 do break

		if t_max.x <= t_max.y {
			cx += step_x
			if cx < 0 || cx >= g.dims.x do break
			t_max.x += t_delta.x
		} else {
			cy += step_y
			if cy < 0 || cy >= g.dims.y do break
			t_max.y += t_delta.y
		}
	}
	return best, ok
}

grid_ground_below :: proc(g: ^Grid, point: [3]f32, max_drop: f32) -> (z: f32, ok: bool) {
	hit, found := grid_raycast(g, point, {0, 0, -1}, max_drop)
	if !found do return 0, false
	return hit.point.z, true
}

@(private = "file")
ray_test_box :: proc(
	g: ^Grid,
	idx: i32,
	origin, dir: [3]f32,
	limit: ^f32,
	best: ^Ray_Hit,
	found: ^bool,
) {
	if g.stamp[idx] == g.gen do return
	g.stamp[idx] = g.gen

	h, hit := ray_aabb(origin, dir, g.boxes[idx], limit^)
	if !hit do return

	best^ = h
	best.index = int(idx)
	limit^ = h.t
	found^ = true
}
