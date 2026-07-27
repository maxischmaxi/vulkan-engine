package physics

import "core:math"
import "core:testing"

// The tick the whole game runs at, so a test measuring "one jump" measures the
// same thing the player feels.
DT :: f32(1.0) / 64

// Counter-strike's numbers, converted at 0.0254 m per unit. Duplicated from the
// game rather than imported: physics has no idea a player exists, and a test
// that moved whenever the tuning did would not be testing the equations.
TEST_FRICTION :: f32(5.2)
TEST_STOP_SPEED :: f32(1.9)
TEST_ACCEL :: f32(5.5)
TEST_AIR_ACCEL :: f32(12.0)
TEST_MAX_WISH :: f32(0.762) // 30 units/s
TEST_WALK :: f32(6.4) // 250 units/s

@(test)
test_friction_brings_a_body_to_a_full_stop :: proc(t: ^testing.T) {
	velocity := [3]f32{TEST_WALK, 0, 0}

	// two seconds is long past when a player who let go of the keys has stopped
	for _ in 0 ..< 128 {
		apply_friction(&velocity, TEST_FRICTION, TEST_STOP_SPEED, DT)
	}

	testing.expectf(t, velocity.x == 0, "still drifting at {} m/s", velocity.x)
}

@(test)
test_acceleration_reaches_walk_speed_and_stops_there :: proc(t: ^testing.T) {
	velocity: [3]f32
	forward := [3]f32{1, 0, 0}

	for _ in 0 ..< 64 {
		accelerate(&velocity, forward, TEST_WALK, TEST_ACCEL, DT)
	}

	testing.expectf(t, close(velocity.x, TEST_WALK), "walked at {} m/s", velocity.x)

	// another second against the cap must not add anything
	for _ in 0 ..< 64 {
		accelerate(&velocity, forward, TEST_WALK, TEST_ACCEL, DT)
	}
	testing.expectf(t, close(velocity.x, TEST_WALK), "cap leaked, ended at {} m/s", velocity.x)
}

// Only the component along the wish direction is capped. This is the property
// every speed trick in the game is built on, so it gets a test of its own.
@(test)
test_acceleration_does_not_cap_sideways_speed :: proc(t: ^testing.T) {
	// already moving east at twice walking speed, now asking to go north
	velocity := [3]f32{2 * TEST_WALK, 0, 0}
	north := [3]f32{0, 1, 0}

	accelerate(&velocity, north, TEST_WALK, TEST_ACCEL, DT)

	testing.expectf(
		t,
		close(velocity.x, 2 * TEST_WALK),
		"the sideways component was touched: {} m/s",
		velocity.x,
	)
	testing.expectf(t, velocity.y > 0, "no speed added along the wish direction")
}

// A strafe jump, played perfectly: hold one strafe key and turn the view with it
// so the wish direction tracks a right angle to the current velocity. Nothing is
// then measured against the cap, the full helping goes on sideways every tick,
// and the speed grows without bound.
//
// The growth is the pythagorean sum, which is the honest reason bunny-hopping
// takes a long chain to pay off: each tick adds a fixed amount to the square of
// the speed, so the speed itself only climbs as its square root.
@(test)
test_air_strafing_gains_speed :: proc(t: ^testing.T) {
	velocity := [3]f32{TEST_WALK, 0, 0}
	start := horizontal_speed(velocity)

	ticks :: 128 // two seconds of flight, or a handful of chained jumps
	for _ in 0 ..< ticks {
		wish := perpendicular_to(velocity)
		air_accelerate(&velocity, wish, TEST_WALK, TEST_MAX_WISH, TEST_AIR_ACCEL, DT)
	}

	speed := horizontal_speed(velocity)
	testing.expectf(t, speed > start + 3, "gained only {} m/s over {}", speed - start, start)

	expected := math.sqrt(start * start + f32(ticks) * TEST_MAX_WISH * TEST_MAX_WISH)
	testing.expectf(t, close(speed, expected), "reached {} m/s, expected {}", speed, expected)
}

// The same thing played by a human: the view turns at a steady rate rather than
// tracking the velocity, so the wish direction drifts out of the right angle and
// the gain tails off. It must still be a gain.
@(test)
test_air_strafing_gains_speed_with_a_steady_turn :: proc(t: ^testing.T) {
	velocity := [3]f32{TEST_WALK, 0, 0}
	start := horizontal_speed(velocity)

	angle := f32(0)
	for _ in 0 ..< 32 {
		angle += math.to_radians(f32(90)) * DT
		wish := [3]f32{-math.sin(angle), math.cos(angle), 0}
		air_accelerate(&velocity, wish, TEST_WALK, TEST_MAX_WISH, TEST_AIR_ACCEL, DT)
	}

	speed := horizontal_speed(velocity)
	testing.expectf(t, speed > start + 0.3, "gained only {} m/s over {}", speed - start, start)
}

// Left of the direction of travel, which is the side a held strafe key puts the
// wish direction on once the view has turned to match.
@(private = "file")
perpendicular_to :: proc(velocity: [3]f32) -> [3]f32 {
	speed := horizontal_speed(velocity)
	if speed < 0.001 do return {0, 1, 0}
	return {-velocity.y / speed, velocity.x / speed, 0}
}

// The other half of the same rule: pointing the wish direction straight down the
// line you are already travelling gives nothing back, which is why holding W in
// the air does not accelerate you.
@(test)
test_air_acceleration_forward_is_capped :: proc(t: ^testing.T) {
	velocity := [3]f32{TEST_WALK, 0, 0}
	forward := [3]f32{1, 0, 0}

	for _ in 0 ..< 64 {
		air_accelerate(&velocity, forward, TEST_WALK, TEST_MAX_WISH, TEST_AIR_ACCEL, DT)
	}

	testing.expectf(t, close(velocity.x, TEST_WALK), "gained forward speed: {} m/s", velocity.x)
}

// Standing still and jumping straight up: air control still gets you moving,
// just no faster than the cap allows in that direction.
@(test)
test_air_acceleration_from_a_standstill_reaches_the_cap :: proc(t: ^testing.T) {
	velocity: [3]f32
	forward := [3]f32{1, 0, 0}

	for _ in 0 ..< 64 {
		air_accelerate(&velocity, forward, TEST_WALK, TEST_MAX_WISH, TEST_AIR_ACCEL, DT)
	}

	testing.expectf(t, close(velocity.x, TEST_MAX_WISH), "ended at {} m/s", velocity.x)
}

@(test)
test_speed_clamp_keeps_direction :: proc(t: ^testing.T) {
	velocity := [3]f32{300, 400, 12}

	clamp_horizontal_speed(&velocity, 50)

	testing.expectf(t, close(horizontal_speed(velocity), 50), "clamped to {}", velocity)
	testing.expectf(t, close(velocity.x / velocity.y, 0.75), "direction changed: {}", velocity)
	testing.expectf(t, velocity.z == 12, "vertical speed was touched: {}", velocity.z)
}

// A landing that is immediately jumped out of must not be charged friction --
// the caller orders the two that way, so this pins the shape friction has to
// keep: a single call, costing a fixed fraction, never a hidden floor.
@(test)
test_one_tick_of_friction_costs_little :: proc(t: ^testing.T) {
	velocity := [3]f32{20, 0, 0}

	apply_friction(&velocity, TEST_FRICTION, TEST_STOP_SPEED, DT)

	lost := 20 - velocity.x
	testing.expectf(t, close(lost, 20 * TEST_FRICTION * DT), "lost {} m/s in one tick", lost)
}
