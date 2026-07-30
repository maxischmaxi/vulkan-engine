package game

import "../physics"
import "core:testing"

// The rule that says who may shoot, tested where both binaries read it. The bug
// this exists for: a match still counting down could be fired through -- flash,
// recoil and a shrinking magazine on the client for shots the server threw
// away. Anything below that passes while the phase gate is missing is not
// pulling its weight.

@(private = "file")
make_range :: proc() -> (gs: Game_State) {
	gs.collision = make([]physics.Aabb, 1)
	gs.collision[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	gs.grid = physics.grid_build(gs.collision)
	// The runner seeds this per test: burst starts roll their seed from it.
	gs.rng = context.random_generator

	// shooter at the origin looking east, target five metres down the ray
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
	// On the floor: pawn_move would set this before any server-side fire, and
	// an airborne shooter would draw random spread on top.
	gs.pawns[0].body.on_ground = true
	gs.pawns[0].loadout = {
		primary   = WEAPON_AK,
		secondary = WEAPON_GLOCK,
	}
	gs.pawns[0].weapon.index = WEAPON_AK
	refill_pawn_ammo(&gs.pawns[0].weapon)
	init_pawn(&gs.pawns[1], {5, 0, 0}, 0)
	return
}

@(private = "file")
destroy_range :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(private = "file")
FIRE :: Pawn_Input {
	buttons     = {.Fire, .Fire_Pressed},
	weapon_slot = -1,
}

@(test)
test_fire_allowed_in_action_phases :: proc(t: ^testing.T) {
	// Warmup is free play and Bomb is still the round being fought: the
	// trigger works in both, exactly as in Live.
	for phase in ([]Match_Phase{.Live, .Warmup, .Bomb}) {
		gs := make_range()
		defer destroy_range(&gs)

		ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, phase)

		testing.expectf(t, ev.fired, "refused during {}", phase)
		testing.expect_value(t, ev.blocked, Fire_Block.None)
	}
}

@(test)
test_no_fire_outside_live :: proc(t: ^testing.T) {
	// every phase that is not the match proper, with the trigger held down
	for phase in ([]Match_Phase{.Idle, .Countdown, .Post, .Freeze, .Round_End, .Halftime}) {
		gs := make_range()
		defer destroy_range(&gs)

		ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, phase)

		testing.expectf(t, !ev.fired, "fired during {}", phase)
		testing.expectf(t, ev.shot_count == 0, "traced during {}", phase)
		testing.expect_value(t, ev.blocked, Fire_Block.Not_In_Match)
		testing.expect_value(t, gs.pawns[1].health, PAWN_MAX_HEALTH)
		testing.expect_value(
			t,
			gs.pawns[0].weapon.ammo[WEAPON_AK].mag,
			WEAPONS[WEAPON_AK].mag_size,
		)
	}
}

@(test)
test_no_fire_when_dead :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	kill_pawn(&gs.pawns[0])

	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Live)

	testing.expect(t, !ev.fired)
	testing.expect_value(t, ev.blocked, Fire_Block.Dead)
	testing.expect_value(t, gs.pawns[1].health, PAWN_MAX_HEALTH)
}

@(test)
test_quiet_tick_is_not_a_refusal :: proc(t: ^testing.T) {
	// The server counts refusals. A tick that never asked to fire must not be
	// one, or every countdown tick of every client would be reported.
	gs := make_range()
	defer destroy_range(&gs)

	input := Pawn_Input {
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Countdown)

	testing.expect(t, !ev.fired)
	testing.expect_value(t, ev.blocked, Fire_Block.None)
}

@(test)
test_slot_switch_allowed_outside_live :: proc(t: ^testing.T) {
	// Holstering is not shooting: it works in a countdown and it works dead,
	// because the next life is bought and picked before it starts.
	for phase in ([]Match_Phase{.Countdown, .Post}) {
		gs := make_range()
		defer destroy_range(&gs)

		input := Pawn_Input {
			weapon_slot = 1, // the secondary
		}
		_ = tick_pawn_weapon(&gs, 0, input, TICK_DT, phase)
		testing.expect_value(t, gs.pawns[0].weapon.index, WEAPON_GLOCK)
	}

	gs := make_range()
	defer destroy_range(&gs)
	kill_pawn(&gs.pawns[0])

	input := Pawn_Input {
		weapon_slot = 1,
	}
	_ = tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)
	testing.expect_value(t, gs.pawns[0].weapon.index, WEAPON_GLOCK)
}

@(test)
test_timers_run_down_outside_live :: proc(t: ^testing.T) {
	// The countdown must not hand the match a frozen weapon: whatever was
	// counting down keeps counting down while the trigger is refused.
	gs := make_range()
	defer destroy_range(&gs)
	w := &gs.pawns[0].weapon
	w.cooldown = 0.5
	w.reload_left = 0.5

	input := Pawn_Input {
		weapon_slot = -1,
	}
	_ = tick_pawn_weapon(&gs, 0, input, TICK_DT, .Countdown)

	testing.expect(t, w.cooldown < 0.5)
	testing.expect(t, w.reload_left < 0.5)
}

@(test)
test_no_reload_starts_outside_live :: proc(t: ^testing.T) {
	// Reloading is handling the weapon under a running clock, so it sits
	// behind the same gate as the trigger. A ticking reload is not affected --
	// that is test_timers_run_down_outside_live.
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].weapon.ammo[WEAPON_AK].mag = 1

	input := Pawn_Input {
		buttons     = {.Reload},
		weapon_slot = -1,
	}
	_ = tick_pawn_weapon(&gs, 0, input, TICK_DT, .Countdown)
	testing.expect_value(t, gs.pawns[0].weapon.reload_left, 0)

	// and the same press once the match is live does start one
	_ = tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)
	testing.expect(t, gs.pawns[0].weapon.reload_left > 0)
}

@(test)
test_countdown_pulls_leave_no_residue :: proc(t: ^testing.T) {
	// A trigger held through the whole countdown must cost nothing and bank
	// nothing: the first live tick has to read exactly like a fresh pull.
	gs := make_range()
	defer destroy_range(&gs)

	for _ in 0 ..< 64 {
		ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Countdown)
		testing.expect(t, !ev.fired)
	}
	testing.expect_value(t, gs.pawns[0].weapon.ammo[WEAPON_AK].mag, WEAPONS[WEAPON_AK].mag_size)
	testing.expect_value(t, gs.pawns[0].weapon.cooldown, 0)

	// the match starts: one shot, and the fire interval holds the next one back
	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Live)
	testing.expect(t, ev.fired)
	testing.expect_value(t, ev.shots[0].pawn, 1)

	ev = tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Live)
	testing.expect(t, !ev.fired)
}
