package physics

import "core:math"
import "core:math/rand"
import "core:testing"

// The grid's one obligation is to never lose a box a linear scan would have
// found. These tests pin it against brute force over randomised scenes, because
// the failure mode of a broadphase is exactly the case nobody thought to write
// a targeted test for.

@(private = "file")
test_rng :: proc(seed: u64) -> rand.Generator {
	@(thread_local)
	state: rand.Default_Random_State
	gen := rand.default_random_generator(&state)
	rand.reset(seed, gen)
	return gen
}

// A map-shaped scene: a huge floor (lands on the oversized list), some long
// walls, and a pile of room-sized boxes.
@(private = "file")
build_test_scene :: proc(rng: rand.Generator, allocator := context.allocator) -> []Aabb {
	boxes := make([dynamic]Aabb, allocator)

	append(&boxes, Aabb{min = {-52, -52, -1}, max = {52, 52, 0}}) // floor
	append(&boxes, Aabb{min = {-52, -52, 0}, max = {-50, 52, 8}}) // west wall
	append(&boxes, Aabb{min = {-52, 50, 0}, max = {52, 52, 8}}) // north wall

	for _ in 0 ..< 150 {
		center := [3]f32 {
			rand.float32_range(-50, 50, rng),
			rand.float32_range(-50, 50, rng),
			rand.float32_range(0, 6, rng),
		}
		half := [3]f32 {
			rand.float32_range(0.05, 4, rng),
			rand.float32_range(0.05, 4, rng),
			rand.float32_range(0.05, 3, rng),
		}
		append(&boxes, Aabb{min = center - half, max = center + half})
	}
	return boxes[:]
}

@(test)
test_grid_candidates_are_a_superset :: proc(t: ^testing.T) {
	rng := test_rng(0x67726964)
	boxes := build_test_scene(rng)
	defer delete(boxes)

	grid := grid_build(boxes)
	defer grid_destroy(&grid)

	for _ in 0 ..< 2000 {
		center := [3]f32 {
			rand.float32_range(-55, 55, rng),
			rand.float32_range(-55, 55, rng),
			rand.float32_range(-2, 8, rng),
		}
		half := [3]f32 {
			rand.float32_range(0.01, 3, rng),
			rand.float32_range(0.01, 3, rng),
			rand.float32_range(0.01, 3, rng),
		}
		bounds := Aabb {
			min = center - half,
			max = center + half,
		}

		candidates := grid_candidates(&grid, bounds)
		for b, i in boxes {
			if !overlaps(bounds, b) do continue

			found := false
			for c in candidates {
				if c == b {
					found = true
					break
				}
			}
			testing.expectf(t, found, "box {} overlaps {} but was not a candidate", i, bounds)
		}

		want := overlaps_any(bounds, boxes)
		testing.expect_value(t, grid_overlaps_any(&grid, bounds), want)
	}
}

@(test)
test_grid_raycast_matches_ray_scene :: proc(t: ^testing.T) {
	rng := test_rng(0x72617963)
	boxes := build_test_scene(rng)
	defer delete(boxes)

	grid := grid_build(boxes)
	defer grid_destroy(&grid)

	for i in 0 ..< 2000 {
		origin := [3]f32 {
			rand.float32_range(-55, 55, rng),
			rand.float32_range(-55, 55, rng),
			rand.float32_range(0.5, 10, rng),
		}

		dir: [3]f32
		// every fourth ray runs exactly along an axis, the way corridor shots do
		if i % 4 == 0 {
			dir[i % 3] = i % 2 == 0 ? 1 : -1
		} else {
			for dot(dir, dir) < 1e-6 {
				dir = {
					rand.float32_range(-1, 1, rng),
					rand.float32_range(-1, 1, rng),
					rand.float32_range(-1, 1, rng),
				}
			}
			dir = dir / math.sqrt(dot(dir, dir))
		}

		max_t := rand.float32_range(1, 200, rng)

		want, want_ok := ray_scene(origin, dir, boxes, max_t)
		got, got_ok := grid_raycast(&grid, origin, dir, max_t)

		testing.expectf(
			t,
			want_ok == got_ok,
			"ray {} from {} along {}: brute ok={}, grid ok={}",
			i,
			origin,
			dir,
			want_ok,
			got_ok,
		)
		if !want_ok || !got_ok do continue

		// t is computed from the box planes alone, so the two must agree exactly
		// -- up to which of two boxes sharing a face at the same t gets reported.
		testing.expectf(t, want.t == got.t, "ray {}: brute t={}, grid t={}", i, want.t, got.t)
	}
}

@(private = "file")
dot :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

// A body walking a fixed route must land on exactly the same positions whether
// the narrow phase saw every box or only the grid's candidates.
@(test)
test_grid_movement_matches_brute_force :: proc(t: ^testing.T) {
	rng := test_rng(0x6d6f7665)
	boxes := build_test_scene(rng)
	defer delete(boxes)

	grid := grid_build(boxes)
	defer grid_destroy(&grid)

	brute := Body {
		position = {0, 0, 0.5},
		radius   = 0.4,
		height   = 1.8,
		step     = 0.5,
	}
	gridded := brute

	dt := f32(1.0 / 64.0)
	for i in 0 ..< 4000 {
		angle := rand.float32_range(0, 2 * math.PI, rng)
		dx := math.cos(angle) * 5 * dt
		dy := math.sin(angle) * 5 * dt
		jump := i % 96 == 0

		if jump && brute.on_ground do brute.velocity.z = 5
		step_move(&brute, boxes, dx, dy)
		apply_gravity(&brute, boxes, 20, dt)

		if jump && gridded.on_ground do gridded.velocity.z = 5
		grid_step_move(&gridded, &grid, dx, dy)
		grid_apply_gravity(&gridded, &grid, 20, dt)

		testing.expectf(
			t,
			brute.position == gridded.position && brute.on_ground == gridded.on_ground,
			"step {}: brute at {} (ground {}), grid at {} (ground {})",
			i,
			brute.position,
			brute.on_ground,
			gridded.position,
			gridded.on_ground,
		)
		if brute.position != gridded.position do break
	}
}

@(test)
test_grid_ground_below :: proc(t: ^testing.T) {
	boxes := []Aabb {
		{min = {-10, -10, -1}, max = {10, 10, 0}},
		{min = {0, 0, 0}, max = {2, 2, 1.5}},
	}

	grid := grid_build(boxes)
	defer grid_destroy(&grid)

	z, ok := grid_ground_below(&grid, {1, 1, 20}, 100)
	testing.expect(t, ok)
	testing.expect(t, close(z, 1.5))

	z2, ok2 := grid_ground_below(&grid, {5, 5, 20}, 100)
	testing.expect(t, ok2)
	testing.expect(t, close(z2, 0))

	_, ok3 := grid_ground_below(&grid, {50, 50, 20}, 100)
	testing.expect(t, !ok3)
}

// The empty world must be handled, not special-cased by every caller.
@(test)
test_grid_empty :: proc(t: ^testing.T) {
	grid := grid_build({})
	defer grid_destroy(&grid)

	testing.expect(t, !grid_overlaps_any(&grid, {min = {-1, -1, -1}, max = {1, 1, 1}}))
	_, ok := grid_raycast(&grid, {0, 0, 5}, {0, 0, -1}, 100)
	testing.expect(t, !ok)
}
