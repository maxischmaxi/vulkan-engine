package physics

import "core:math/linalg"
import "core:testing"

// Thrown grenades run through this on both ends of the wire, so anything
// non-deterministic or unbounded here becomes a projectile that lands in a
// different place on two machines.

@(private = "file")
make_floor :: proc() -> (boxes: []Aabb, g: Grid) {
	boxes = make([]Aabb, 1)
	boxes[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	g = grid_build(boxes)
	return
}

@(private = "file")
destroy_floor :: proc(boxes: []Aabb, g: ^Grid) {
	grid_destroy(g)
	delete(boxes)
}

@(test)
test_bounce_falls_and_settles :: proc(t: ^testing.T) {
	boxes, g := make_floor()
	defer destroy_floor(boxes, &g)

	position := [3]f32{0, 0, 5}
	velocity := [3]f32{0, 0, 0}
	radius := f32(0.1)

	resting := false
	for _ in 0 ..< 600 {
		r := bounce_move(&g, &position, &velocity, radius, 20.3, 0.4, 0.8, 1.0 / 64)
		if r.resting {
			resting = true
			break
		}
	}

	testing.expect(t, resting, "a dropped grenade must come to rest")
	// On the floor, not through it and not hovering.
	testing.expectf(t, position.z > 0, "settled below the floor at z {}", position.z)
	testing.expectf(t, position.z < 0.3, "settled floating at z {}", position.z)
}

@(test)
test_bounce_loses_energy :: proc(t: ^testing.T) {
	boxes, g := make_floor()
	defer destroy_floor(boxes, &g)

	position := [3]f32{0, 0, 3}
	velocity := [3]f32{0, 0, 0}
	peak_after_bounce := f32(0)
	bounced := false

	for _ in 0 ..< 400 {
		r := bounce_move(&g, &position, &velocity, 0.1, 20.3, 0.4, 0.8, 1.0 / 64)
		if r.bounces > 0 do bounced = true
		if bounced do peak_after_bounce = max(peak_after_bounce, position.z)
		if r.resting do break
	}

	testing.expect(t, bounced, "it never hit the floor")
	// It bounced back up, but nowhere near where it was dropped from.
	testing.expectf(t, peak_after_bounce < 3, "bounced back to {}, higher than the drop", peak_after_bounce)
}

// The property the wire depends on: same inputs, same landing spot, bit for
// bit. Two independent worlds so no shared mutable state can couple them.
@(test)
test_bounce_is_deterministic :: proc(t: ^testing.T) {
	boxes_a, ga := make_floor()
	defer destroy_floor(boxes_a, &ga)
	boxes_b, gb := make_floor()
	defer destroy_floor(boxes_b, &gb)

	pa := [3]f32{0, 0, 2}
	va := [3]f32{7, 3, 4}
	pb := pa
	vb := va

	for _ in 0 ..< 300 {
		bounce_move(&ga, &pa, &va, 0.1, 20.3, 0.45, 0.75, 1.0 / 64)
		bounce_move(&gb, &pb, &vb, 0.1, 20.3, 0.45, 0.75, 1.0 / 64)
	}

	testing.expect_value(t, pa.x, pb.x)
	testing.expect_value(t, pa.y, pb.y)
	testing.expect_value(t, pa.z, pb.z)
}

// A grenade thrown flat at a wall has to come back, not stop inside it.
@(test)
test_bounce_off_a_wall :: proc(t: ^testing.T) {
	boxes := make([]Aabb, 2)
	boxes[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	boxes[1] = {
		min = {5, -10, 0},
		max = {5.5, 10, 5},
	} // wall facing -x
	g := grid_build(boxes)
	defer destroy_floor(boxes, &g)

	position := [3]f32{0, 0, 1}
	velocity := [3]f32{18, 0, 0}
	radius := f32(0.1)

	hit := false
	for _ in 0 ..< 64 {
		r := bounce_move(&g, &position, &velocity, radius, 20.3, 0.5, 0.9, 1.0 / 64)
		if r.hit_wall {
			hit = true
			break
		}
	}

	testing.expect(t, hit, "never reached the wall")
	testing.expect(t, velocity.x < 0, "must be travelling back from the wall")
	testing.expectf(t, position.x < 5, "ended up inside the wall at x {}", position.x)
}

// Speed alone must not count as resting: at the top of its arc a grenade is
// slow and very much still in the air.
@(test)
test_slow_in_midair_is_not_resting :: proc(t: ^testing.T) {
	boxes, g := make_floor()
	defer destroy_floor(boxes, &g)

	position := [3]f32{0, 0, 20}
	velocity := [3]f32{0, 0, 0}
	r := bounce_move(&g, &position, &velocity, 0.1, 20.3, 0.4, 0.8, 1.0 / 64)
	testing.expect(t, !r.resting, "hanging in the air is not resting")
	testing.expect(t, velocity.z < 0, "gravity must still apply")
}

// Bounded work per step: a projectile wedged in a corner must not spin the
// loop forever, and must not tunnel out of the world either.
@(test)
test_bounce_in_a_corner_terminates :: proc(t: ^testing.T) {
	boxes := make([]Aabb, 3)
	boxes[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	boxes[1] = {
		min = {1, -10, 0},
		max = {1.5, 10, 5},
	}
	boxes[2] = {
		min = {-10, 1, 0},
		max = {10, 1.5, 5},
	}
	g := grid_build(boxes)
	defer destroy_floor(boxes, &g)

	position := [3]f32{0.5, 0.5, 0.5}
	velocity := [3]f32{40, 40, 0}

	for _ in 0 ..< 200 {
		r := bounce_move(&g, &position, &velocity, 0.1, 20.3, 0.6, 0.9, 1.0 / 64)
		testing.expect(t, r.bounces <= MAX_BOUNCES_PER_STEP)
	}

	// Still in the pocket between the two walls and the floor.
	testing.expectf(t, position.x < 1.6 && position.y < 1.6, "escaped the corner to {}", position)
	testing.expect(t, position.z > -1, "fell through the floor")
	testing.expect(t, linalg.length(velocity) < 40 * 2, "gained energy in the corner")
}
