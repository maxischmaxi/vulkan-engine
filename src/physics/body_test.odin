package physics

import "core:testing"

// Player-shaped body: 0.6 m wide, 1.8 m tall, Source's 18-unit step height.
test_body :: proc(x, y, z: f32) -> Body {
	return {position = {x, y, z}, radius = 0.3, height = 1.8, step = 0.45, on_ground = true}
}

GROUND :: Aabb {
	min = {-50, -50, -2},
	max = {50, 50, 0},
}

@(test)
test_walks_into_wall_and_stops :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND, {min = {2, -5, 0}, max = {2.6, 5, 5}}}

	body := test_body(0, 0, 0)
	for _ in 0 ..< 200 {
		step_move(&body, boxes, 0.05, 0)
	}

	// stopped with its leading edge against the wall face at x = 2
	testing.expectf(
		t,
		close(body.position.x, 2 - body.radius),
		"stopped at {}, want {}",
		body.position.x,
		2 - body.radius,
	)
}

// The whole point of the substepping: one long move must not pass through a
// wall thinner than the move itself.
@(test)
test_long_step_cannot_tunnel :: proc(t: ^testing.T) {
	wall := Aabb {
		min = {2, -5, 0},
		max = {2.6, 5, 5},
	}
	boxes := []Aabb{GROUND, wall}

	// 10 m in a single call, against a wall 0.6 m thick
	body := test_body(0, 0, 0)
	step_move(&body, boxes, 10, 0)

	testing.expectf(
		t,
		body.position.x < 2,
		"ended up at x = {}, which is past the wall",
		body.position.x,
	)
	testing.expect(t, !overlaps(body_aabb(body), wall), "must not end inside the wall")
}

@(test)
test_falling_fast_cannot_tunnel :: proc(t: ^testing.T) {
	floor := Aabb {
		min = {-5, -5, 0},
		max = {5, 5, 0.06},
	} // a thin slab, nothing underneath
	boxes := []Aabb{floor}

	body := test_body(0, 0, 5)
	body.on_ground = false
	body.velocity.z = -60 // far faster than gravity ever gets it

	for _ in 0 ..< 60 {
		apply_gravity(&body, boxes, 18, 1.0 / 64)
		if body.on_ground do break
	}

	testing.expect(t, body.on_ground, "should have landed on the slab")
	testing.expectf(t, close(body.position.z, 0.06), "landed at z = {}", body.position.z)
}

@(test)
test_steps_up_a_low_ledge :: proc(t: ^testing.T) {
	// extends past the walk so the body ends up on top of it, not beyond it
	boxes := []Aabb{GROUND, {min = {2, -5, 0}, max = {40, 5, 0.30}}}

	body := test_body(0, 0, 0)
	for _ in 0 ..< 200 {
		step_move(&body, boxes, 0.05, 0)
		apply_gravity(&body, boxes, 18, 1.0 / 64)
	}

	testing.expectf(t, body.position.x > 3, "did not climb the ledge, x = {}", body.position.x)
	testing.expectf(t, close(body.position.z, 0.30), "not standing on it, z = {}", body.position.z)
}

@(test)
test_does_not_step_up_a_tall_ledge :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND, {min = {2, -5, 0}, max = {6, 5, 0.60}}}

	body := test_body(0, 0, 0)
	for _ in 0 ..< 200 {
		step_move(&body, boxes, 0.05, 0)
		apply_gravity(&body, boxes, 18, 1.0 / 64)
	}

	testing.expectf(
		t,
		close(body.position.x, 2 - body.radius),
		"climbed something taller than its step height, x = {}",
		body.position.x,
	)
	testing.expect(t, close(body.position.z, 0))
}

// Regression: a 6 cm indoor floor slab is real collision geometry the body
// permanently overlaps while standing on it. Combined with the ~1e-12 that
// cos(90 degrees) is not, an earlier version snapped the body across the slab's
// entire width on every frame -- and from there it climbed walls.
@(test)
test_standing_on_slab_does_not_teleport :: proc(t: ^testing.T) {
	slab := Aabb {
		min = {-7, -6, 0},
		max = {7, 6, 0.06},
	}
	boxes := []Aabb{GROUND, slab}

	body := test_body(6.7, 0, 0.06)
	start := body.position

	// walking north, with the float noise a cos(90 degrees) actually produces
	for _ in 0 ..< 120 {
		step_move(&body, boxes, -4.4e-12, 0.05)
		apply_gravity(&body, boxes, 18, 1.0 / 64)
	}

	testing.expectf(
		t,
		abs(body.position.x - start.x) < 0.001,
		"drifted sideways to x = {} from {}",
		body.position.x,
		start.x,
	)
	testing.expectf(t, close(body.position.z, 0.06), "left the slab, z = {}", body.position.z)
}

@(test)
test_gravity_lands_on_ground :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND}

	body := test_body(0, 0, 5)
	body.on_ground = false

	for _ in 0 ..< 200 {
		apply_gravity(&body, boxes, 18, 1.0 / 64)
	}

	testing.expect(t, body.on_ground)
	testing.expect(t, close(body.position.z, 0))
	testing.expect(t, close(body.velocity.z, 0))
}

@(test)
test_ceiling_stops_upward_motion :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND, {min = {-5, -5, 2.0}, max = {5, 5, 3.0}}}

	body := test_body(0, 0, 0)
	body.on_ground = false
	body.velocity.z = 10

	apply_gravity(&body, boxes, 18, 1.0 / 64)
	for _ in 0 ..< 20 {
		if body.velocity.z <= 0 do break
		apply_gravity(&body, boxes, 18, 1.0 / 64)
	}

	testing.expect(
		t,
		body.position.z + body.height <= 2.0 + PENETRATION_SLOP,
		"head went through the ceiling",
	)
	testing.expect(t, !body.on_ground, "hitting a ceiling is not landing")
}

// Same movement split differently must land in the same place -- this is what
// makes the fixed tick worth having.
@(test)
test_substepping_is_consistent :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND, {min = {2, -5, 0}, max = {2.6, 5, 5}}}

	coarse := test_body(0, 0, 0)
	step_move(&coarse, boxes, 1.9, 0)

	fine := test_body(0, 0, 0)
	for _ in 0 ..< 19 {
		step_move(&fine, boxes, 0.1, 0)
	}

	testing.expectf(
		t,
		abs(coarse.position.x - fine.position.x) < 0.001,
		"coarse ended at {}, fine at {}",
		coarse.position.x,
		fine.position.x,
	)
}
