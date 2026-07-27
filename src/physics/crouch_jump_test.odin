package physics

import "core:testing"

// The crouch-jump, end to end: the same tick order the game runs, against a
// ledge sized so a standing jump misses it and a ducked one does not. Everything
// else about the movement can be argued over; this is the one behaviour the maps
// are laid out around, so it is pinned here rather than left to be noticed.

TEST_GRAVITY :: f32(20.32) // sv_gravity 800, at 0.0254 m per unit
TEST_JUMP :: f32(7.5) // clears 1.38 m, near counter-strike's 54 units
TEST_STAND :: f32(1.8)
TEST_CROUCH :: f32(0.9)

// Above the 1.38 m a standing jump reaches, below the 1.83 m a ducked one does.
LEDGE_TOP :: f32(1.6)

FLOOR :: Aabb {
	min = {-20, -5, -2},
	max = {20, 5, 0},
}
LEDGE :: Aabb {
	min = {3, -5, -2},
	max = {20, 5, LEDGE_TOP},
}

// Runs one jump from x = 0 toward the ledge, ducking at the top of the arc if
// asked to, and reports where it ended up.
@(private = "file")
jump_at_ledge :: proc(duck_at_apex: bool) -> Body {
	boxes := []Aabb{FLOOR, LEDGE}

	body := Body {
		position  = {0, 0, 0},
		radius    = 0.3,
		height    = TEST_STAND,
		step      = 0.45,
		on_ground = true,
	}

	// Launch. The run-up is already at walking speed, which is what puts the top
	// of the arc a third of a metre short of the ledge.
	body.velocity = {6.4, 0, TEST_JUMP}
	body.on_ground = false
	ducked := false

	for _ in 0 ..< 128 {
		if duck_at_apex && !ducked && body.velocity.z <= 0 {
			duck_hull(&body, TEST_CROUCH)
			ducked = true
		}

		blocked_x, _ := step_move(&body, boxes, body.velocity.x * DT, 0)
		if blocked_x do body.velocity.x = 0

		apply_gravity(&body, boxes, TEST_GRAVITY, DT)
		if body.on_ground do break
	}
	return body
}

@(test)
test_a_standing_jump_falls_short_of_the_ledge :: proc(t: ^testing.T) {
	body := jump_at_ledge(duck_at_apex = false)

	testing.expect(t, body.on_ground, "never landed")
	testing.expectf(
		t,
		close(body.position.z, 0),
		"got onto a {} m ledge without ducking, z = {}",
		LEDGE_TOP,
		body.position.z,
	)
	testing.expectf(
		t,
		body.position.x < 3,
		"ended up past the ledge face, x = {}",
		body.position.x,
	)
}

@(test)
test_ducking_in_mid_air_clears_the_ledge :: proc(t: ^testing.T) {
	body := jump_at_ledge(duck_at_apex = true)

	testing.expect(t, body.on_ground, "never landed")
	testing.expectf(t, close(body.position.z, LEDGE_TOP), "landed at z = {}", body.position.z)
	testing.expectf(t, body.position.x > 3, "landed short of the ledge, x = {}", body.position.x)
}

@(test)
test_ducking_on_the_ground_leaves_the_feet_alone :: proc(t: ^testing.T) {
	body := Body {
		position  = {0, 0, 0},
		radius    = 0.3,
		height    = TEST_STAND,
		on_ground = true,
	}

	moved := duck_hull(&body, TEST_CROUCH)

	testing.expectf(t, moved == 0, "the feet moved {} m", moved)
	testing.expect(t, body.position.z == 0)
	testing.expect(t, body.height == TEST_CROUCH)
}

@(test)
test_ducking_in_the_air_lifts_the_feet_and_lowers_the_head :: proc(t: ^testing.T) {
	body := Body {
		position  = {0, 0, 4},
		radius    = 0.3,
		height    = TEST_STAND,
		on_ground = false,
	}
	head := body.position.z + body.height

	moved := duck_hull(&body, TEST_CROUCH)

	expected := (TEST_STAND - TEST_CROUCH) * 0.5
	testing.expectf(t, close(moved, expected), "the feet moved {} m, expected {}", moved, expected)
	testing.expectf(t, close(body.position.z, 4 + expected), "feet at {}", body.position.z)
	testing.expectf(
		t,
		close(body.position.z + body.height, head - expected),
		"the head went to {}, expected {}",
		body.position.z + body.height,
		head - expected,
	)
}

// Duck and unduck repeatedly in mid-air and you must end up exactly where the
// arc would have put you anyway. Anything else is a free ladder.
@(test)
test_ducking_and_standing_in_the_air_nets_out :: proc(t: ^testing.T) {
	boxes := []Aabb{FLOOR}

	body := Body {
		position  = {0, 0, 4},
		radius    = 0.3,
		height    = TEST_STAND,
		on_ground = false,
	}

	for _ in 0 ..< 20 {
		duck_hull(&body, TEST_CROUCH)
		_, ok := stand_hull(&body, boxes, TEST_STAND)
		testing.expect(t, ok, "nothing was in the way, so standing must succeed")
	}

	testing.expectf(t, close(body.position.z, 4), "drifted to z = {}", body.position.z)
	testing.expect(t, body.height == TEST_STAND)
}

@(test)
test_standing_up_under_a_ceiling_is_refused :: proc(t: ^testing.T) {
	boxes := []Aabb{FLOOR, {min = {-5, -5, 1.2}, max = {5, 5, 3}}}

	body := Body {
		position  = {0, 0, 0},
		radius    = 0.3,
		height    = TEST_CROUCH,
		on_ground = true,
	}

	_, ok := stand_hull(&body, boxes, TEST_STAND)

	testing.expect(t, !ok, "stood up through a ceiling 1.2 m over the floor")
	testing.expect(t, body.height == TEST_CROUCH)
}

// The mid-air half of the same rule: the feet drop back on standing up, so a
// player hugging a ledge from below has to stay ducked.
@(test)
test_standing_up_in_the_air_is_refused_without_room_below :: proc(t: ^testing.T) {
	boxes := []Aabb{FLOOR, {min = {-5, -5, 0}, max = {5, 5, 3.9}}}

	body := Body {
		position  = {0, 0, 3.95},
		radius    = 0.3,
		height    = TEST_CROUCH,
		on_ground = false,
	}

	_, ok := stand_hull(&body, boxes, TEST_STAND)

	testing.expect(t, !ok, "dropped its feet into the block it is standing over")
	testing.expectf(t, close(body.position.z, 3.95), "moved to z = {}", body.position.z)
}
