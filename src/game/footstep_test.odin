package game

import "core:testing"

// The cadence is now shared between the server (remote steps) and the client
// (its own), so a drift here is two players hearing different rhythms for the
// same feet.

@(test)
test_footstep_cadence :: proc(t: ^testing.T) {
	// Running flat out: a step every FOOTSTEP_STRIDE metres of ground covered.
	travelled: f32
	steps := 0
	distance: f32
	for _ in 0 ..< TICK_RATE * 4 {
		stepped: bool
		travelled, stepped = footstep_step(travelled, WALK_SPEED, true, true, TICK_DT)
		distance += WALK_SPEED * TICK_DT
		if stepped do steps += 1
	}

	expected := int(distance / FOOTSTEP_STRIDE)
	testing.expectf(
		t,
		abs(steps - expected) <= 1,
		"{} steps over {} m, wanted ~{}",
		steps,
		distance,
		expected,
	)
}

@(test)
test_footstep_silence :: proc(t: ^testing.T) {
	// Every way of being quiet, each starting from a full accumulator so a
	// reset is visible.
	full := FOOTSTEP_STRIDE * 0.99

	next, stepped := footstep_step(full, WALK_SPEED, false, true, TICK_DT)
	testing.expect(t, !stepped, "airborne makes no sound")
	testing.expect_value(t, next, 0)

	next, stepped = footstep_step(full, WALK_SPEED, true, false, TICK_DT)
	testing.expect(t, !stepped, "the dead do not walk")
	testing.expect_value(t, next, 0)

	next, stepped = footstep_step(full, 0, true, true, TICK_DT)
	testing.expect(t, !stepped, "standing still is silent")
	testing.expect_value(t, next, 0)

	// Just under the threshold: this is what walking and crouching produce.
	next, stepped = footstep_step(full, FOOTSTEP_MIN_SPEED * 0.99, true, true, TICK_DT)
	testing.expect(t, !stepped, "sneaking is silent")
	testing.expect_value(t, next, 0)
}

// The stances that must stay silent, expressed as the movement code produces
// them -- so a rebalance of any factor fails here rather than in a match.
@(test)
test_slow_stances_stay_silent :: proc(t: ^testing.T) {
	quiet := [?]struct {
		name:   string,
		factor: f32,
	}{{"walk", SLOW_FACTOR}, {"crouch", CROUCH_FACTOR}, {"scoped", ZOOM_FACTOR}}

	for stance in quiet {
		speed := WALK_SPEED * stance.factor
		_, stepped := footstep_step(FOOTSTEP_STRIDE * 0.99, speed, true, true, TICK_DT)
		testing.expectf(t, !stepped, "{} at {} m/s must be silent", stance.name, speed)
	}
}

// The cadence measures ground covered, not the velocity vector -- the server's
// bots move by direct displacement and keep a zero horizontal velocity, so
// reading the vector silenced every one of them.
@(test)
test_footstep_speed_from_displacement :: proc(t: ^testing.T) {
	// A tick's worth of running, measured back out.
	step := WALK_SPEED * TICK_DT
	speed := footstep_speed({0, 0, 0}, {step, 0, 0}, TICK_DT)
	testing.expectf(t, abs(speed - WALK_SPEED) < 0.01, "expected {}, got {}", WALK_SPEED, speed)

	// Height does not count towards the stride: falling is not walking.
	testing.expect_value(t, footstep_speed({0, 0, 0}, {0, 0, 5}, TICK_DT), 0)

	// A respawn is a teleport, not a stride worth of distance.
	testing.expect_value(t, footstep_speed({0, 0, 0}, {40, 40, 0}, TICK_DT), 0)

	// The guard sits well above what movement can reach, so a bunny hop at the
	// speed cap still registers.
	fastest := MAX_SPEED * TICK_DT
	testing.expect(t, fastest < FOOTSTEP_TELEPORT, "the speed cap must stay under the guard")
	testing.expect(t, footstep_speed({0, 0, 0}, {fastest, 0, 0}, TICK_DT) > 0)

	testing.expect_value(t, footstep_speed({0, 0, 0}, {1, 0, 0}, 0), 0)
}

// A bot walking at its own pace has to be audible; the human threshold sits
// above its speed, which is the whole reason footstep_min_speed exists.
@(test)
test_bots_are_audible_at_their_own_pace :: proc(t: ^testing.T) {
	travelled: f32
	steps := 0
	for _ in 0 ..< TICK_RATE * 4 {
		stepped: bool
		travelled, stepped = footstep_step(
			travelled,
			BOT_WALK_SPEED,
			true,
			true,
			TICK_DT,
			footstep_min_speed(true),
		)
		if stepped do steps += 1
	}
	testing.expect(t, steps > 0, "a walking bot must make noise")

	// With the human threshold it would be silent -- pinning the bug this
	// guards against rather than just the fix.
	travelled = 0
	human_steps := 0
	for _ in 0 ..< TICK_RATE * 4 {
		stepped: bool
		travelled, stepped = footstep_step(travelled, BOT_WALK_SPEED, true, true, TICK_DT)
		if stepped do human_steps += 1
	}
	testing.expect_value(t, human_steps, 0)
}

@(test)
test_sound_audible_range :: proc(t: ^testing.T) {
	listener := [3]f32{0, 0, 0}

	testing.expect(t, sound_audible(listener, {10, 0, 0}, FOOTSTEP_HEARING_RANGE))
	testing.expect(t, !sound_audible(listener, {FOOTSTEP_HEARING_RANGE + 1, 0, 0}, FOOTSTEP_HEARING_RANGE))

	// Gunfire carries much further than feet -- the asymmetry is deliberate.
	far := [3]f32{FOOTSTEP_HEARING_RANGE + 20, 0, 0}
	testing.expect(t, !sound_audible(listener, far, FOOTSTEP_HEARING_RANGE))
	testing.expect(t, sound_audible(listener, far, GUNSHOT_HEARING_RANGE))

	// Height counts: a floor above is not in earshot just because it is
	// directly overhead.
	testing.expect(t, !sound_audible(listener, {0, 0, FOOTSTEP_HEARING_RANGE + 1}, FOOTSTEP_HEARING_RANGE))
}

// Hearing has to outreach seeing, or fog of war would take information away
// that the player is supposed to keep.
@(test)
test_hearing_is_not_trimmed_below_use :: proc(t: ^testing.T) {
	testing.expect(t, GUNSHOT_HEARING_RANGE > FOOTSTEP_HEARING_RANGE)
	// A duel happens well inside a footstep's radius; if this ever inverts,
	// players would see enemies they cannot hear.
	testing.expect(t, FOOTSTEP_HEARING_RANGE > 20)
}
