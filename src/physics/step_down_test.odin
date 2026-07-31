package physics

import "core:testing"

// The step-down half of stair walking: snap_to_ground runs after every
// grounded horizontal move, so a descent stays glued to the treads instead of
// free-falling past each one. Ticks run step_move then apply_gravity, the
// order walk_move uses.

@(test)
test_walking_down_a_tread_stays_grounded :: proc(t: ^testing.T) {
	// an upper floor one tread above the ground, ending at x = 0
	boxes := []Aabb{GROUND, {min = {-10, -5, 0}, max = {0, 5, 0.3}}}

	body := test_body(-1, 0, 0.3)
	for _ in 0 ..< 80 {
		step_move(&body, boxes, 0.05, 0)
		apply_gravity(&body, boxes, 18, 1.0 / 64)
		testing.expectf(t, body.on_ground, "went airborne at x = {}", body.position.x)
	}

	testing.expectf(t, body.position.x > 1, "did not cross the edge, x = {}", body.position.x)
	testing.expectf(
		t,
		close(body.position.z, 0),
		"not on the lower floor, z = {}",
		body.position.z,
	)
}

@(test)
test_descending_a_staircase_never_goes_airborne :: proc(t: ^testing.T) {
	// dust2's steepest stairs -- 0.5 m treads dropping 0.3 m each -- run at
	// full walk speed
	boxes := []Aabb {
		GROUND,
		{min = {-10, -5, 0}, max = {0, 5, 1.5}},
		{min = {0, -5, 0}, max = {0.5, 5, 1.2}},
		{min = {0.5, -5, 0}, max = {1.0, 5, 0.9}},
		{min = {1.0, -5, 0}, max = {1.5, 5, 0.6}},
		{min = {1.5, -5, 0}, max = {2.0, 5, 0.3}},
	}

	body := test_body(-1, 0, 1.5)
	dx := f32(6.35) / 64
	for _ in 0 ..< 64 {
		step_move(&body, boxes, dx, 0)
		apply_gravity(&body, boxes, 20.32, 1.0 / 64)
		testing.expectf(t, body.on_ground, "went airborne at x = {}", body.position.x)
	}

	testing.expectf(t, body.position.x > 3, "did not clear the stairs, x = {}", body.position.x)
	testing.expectf(t, close(body.position.z, 0), "not at the bottom, z = {}", body.position.z)
}

@(test)
test_a_drop_taller_than_a_step_is_still_a_fall :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND, {min = {-10, -5, 0}, max = {0, 5, 0.6}}}

	// one move carries the trailing edge past the ledge
	body := test_body(0.28, 0, 0.6)
	step_move(&body, boxes, 0.05, 0)
	testing.expect(t, body.position.z == 0.6, "the snap grabbed a floor deeper than one step")
	testing.expect(t, body.on_ground, "step_move must not clear the ground flag itself")

	apply_gravity(&body, boxes, 20.32, 1.0 / 64)
	testing.expect(t, !body.on_ground, "walking off a ledge must still be a fall")

	for _ in 0 ..< 100 {
		apply_gravity(&body, boxes, 20.32, 1.0 / 64)
	}
	testing.expect(t, body.on_ground)
	testing.expectf(t, close(body.position.z, 0), "landed at z = {}", body.position.z)
}

@(test)
test_a_jump_is_not_snapped_back_down :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND}

	// exactly what walk_move does on the jump tick: velocity up, flag cleared
	body := test_body(0, 0, 0)
	body.velocity.z = 7.5
	body.on_ground = false

	apex: f32
	for _ in 0 ..< 200 {
		step_move(&body, boxes, 0.05, 0)
		apply_gravity(&body, boxes, 20.32, 1.0 / 64)
		apex = max(apex, body.position.z)
		if body.on_ground do break
	}

	testing.expectf(t, apex > 1.3, "jump was cut short, apex = {}", apex)
	testing.expect(t, body.on_ground, "should have landed again")
}

@(test)
test_snap_is_a_noop_when_standing_still :: proc(t: ^testing.T) {
	boxes := []Aabb{GROUND}

	body := test_body(0, 0, 0)
	start := body.position
	step_move(&body, boxes, 0, 0)

	testing.expect(t, body.position == start, "standing still must not move the body")
}
