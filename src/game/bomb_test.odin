package game

import "core:testing"

// The bomb's pure rules: site volumes, the timing steppers, the explosion
// falloff. The server state machine leans on exactly these; a drift here is
// a plant that works on one end and not the other.

@(test)
test_bomb_site_at :: proc(t: ^testing.T) {
	// dead center of both pads
	a := [3]f32{30, 32, 1.5}
	b := [3]f32{-34, 30, GROUND_Z + 0.2}
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, a), 0)
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, b), 1)

	// outside in x, outside in y, far above, far below
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, [3]f32{0, 0, 0}), -1)
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, [3]f32{19, 32, 1.5}), -1)
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, [3]f32{30, 24, 1.5}), -1)
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, [3]f32{30, 32, 6}), -1)
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, [3]f32{30, 32, -1}), -1)

	// the jump band: slightly above the floor still counts
	testing.expect_value(t, bomb_site_at(MAP_BOMBSITES, [3]f32{30, 32, 3.9}), 0)
}

@(test)
test_bomb_plant_stepper :: proc(t: ^testing.T) {
	// held all the way through: completes after BOMB_PLANT_TIME
	progress: f32
	done: bool
	ticks := 0
	for !done {
		progress, done = bomb_plant_step(progress, true, TICK_DT)
		ticks += 1
		if ticks > 10 * TICK_RATE do break
	}
	testing.expect(t, done, "plant never completed")
	plant_time := f32(BOMB_PLANT_TIME)
	expected := int(plant_time * TICK_RATE) + 1
	testing.expectf(t, abs(ticks - expected) <= 1, "plant took {} ticks, wanted ~{}", ticks, expected)

	// releasing resets to zero, not to a pause
	progress = 2.5
	progress, done = bomb_plant_step(progress, false, TICK_DT)
	testing.expect_value(t, progress, 0)
	testing.expect(t, !done)
}

@(test)
test_bomb_defuse_stepper :: proc(t: ^testing.T) {
	progress: f32
	done: bool
	ticks := 0
	for !done {
		progress, done = bomb_defuse_step(progress, true, TICK_DT)
		ticks += 1
		if ticks > 20 * TICK_RATE do break
	}
	testing.expect(t, done, "defuse never completed")
	defuse_time := f32(BOMB_DEFUSE_TIME)
	expected := int(defuse_time * TICK_RATE) + 1
	testing.expectf(t, abs(ticks - expected) <= 1, "defuse took {} ticks, wanted ~{}", ticks, expected)

	progress = 9.9
	progress, done = bomb_defuse_step(progress, false, TICK_DT)
	testing.expect_value(t, progress, 0)
	testing.expect(t, !done)
}

@(test)
test_bomb_explosion_falloff :: proc(t: ^testing.T) {
	testing.expect_value(t, bomb_explosion_damage(0), BOMB_DAMAGE_MAX)
	testing.expect_value(t, bomb_explosion_damage(BOMB_DAMAGE_RADIUS), 0)
	testing.expect_value(t, bomb_explosion_damage(BOMB_DAMAGE_RADIUS + 5), 0)
	half := bomb_explosion_damage(BOMB_DAMAGE_RADIUS * 0.5)
	testing.expectf(t, half == BOMB_DAMAGE_MAX / 2, "half distance should halve, got {}", half)
}
