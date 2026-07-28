package game

import "../physics"
import "core:testing"

// The rewind under the microscope: shots must land where the target stood at
// the rewound tick, and begin/end must leave no trace beyond the damage dealt.

@(private = "file")
lag_range :: proc() -> (gs: Game_State) {
	gs.collision = make([]physics.Aabb, 1)
	gs.collision[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	gs.grid = physics.grid_build(gs.collision)

	// shooter at the origin looking east, target five metres down the ray;
	// the shooter carries the ak so the fire tests reach that far
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
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
destroy_lag_range :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(private = "file")
FIRE :: Pawn_Input {
	buttons     = {.Fire_Pressed},
	weapon_slot = -1,
}

@(test)
test_rewind_hits_where_target_was :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)

	hist: Lag_History
	lag_history_record(&hist, &gs, 10)

	// the target has since strafed well off the ray
	gs.pawns[1].body.position = {5, 3, 0}

	rw, ok := lag_comp_begin(&hist, &gs, 10, 0)
	testing.expect(t, ok)
	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT)
	lag_comp_end(&gs, &rw)

	testing.expect(t, ev.fired)
	testing.expect_value(t, ev.shot.pawn, 1)
	testing.expect(t, gs.pawns[1].health < PAWN_MAX_HEALTH)
	// the hull is back where the present says it is
	testing.expect_value(t, gs.pawns[1].body.position, [3]f32{5, 3, 0})
}

@(test)
test_no_rewind_misses_moved_target :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)

	gs.pawns[1].body.position = {5, 3, 0}

	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT)
	testing.expect(t, ev.fired)
	testing.expect_value(t, ev.shot.pawn, -1)
	testing.expect_value(t, gs.pawns[1].health, PAWN_MAX_HEALTH)
}

@(test)
test_rewind_restores_exactly :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)

	hist: Lag_History
	lag_history_record(&hist, &gs, 5)

	gs.pawns[1].body.position = {7, -2, 0.5}
	gs.pawns[1].body.height = CROUCH_HEIGHT
	shooter_before := gs.pawns[0].body

	rw, ok := lag_comp_begin(&hist, &gs, 5, 0)
	testing.expect(t, ok)
	lag_comp_end(&gs, &rw)

	testing.expect_value(t, gs.pawns[1].body.position, [3]f32{7, -2, 0.5})
	testing.expect_value(t, gs.pawns[1].body.height, f32(CROUCH_HEIGHT))
	testing.expect_value(t, gs.pawns[1].body.radius, f32(PLAYER_RADIUS))
	testing.expect_value(t, gs.pawns[0].body, shooter_before)
}

@(test)
test_dead_at_rewind_tick_not_hit :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)

	// dead when the shooter's view was made, respawned on the ray since
	kill_pawn(&gs.pawns[1])
	hist: Lag_History
	lag_history_record(&hist, &gs, 10)
	init_pawn(&gs.pawns[1], {5, 0, 0}, 0)

	rw, ok := lag_comp_begin(&hist, &gs, 10, 0)
	testing.expect(t, ok)
	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT)
	lag_comp_end(&gs, &rw)

	testing.expect_value(t, ev.shot.pawn, -1)
	testing.expect(t, gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[1].health, PAWN_MAX_HEALTH)
}

@(test)
test_kill_during_rewind_survives_restore :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)
	gs.pawns[1].armor = 0
	gs.pawns[1].health = WEAPONS[WEAPON_AK].damage // exactly one rifle hit

	hist: Lag_History
	lag_history_record(&hist, &gs, 10)
	gs.pawns[1].body.position = {5, 3, 0}

	rw, ok := lag_comp_begin(&hist, &gs, 10, 0)
	testing.expect(t, ok)
	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT)
	lag_comp_end(&gs, &rw)

	testing.expect(t, ev.killed)
	testing.expect(t, !gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[1].deaths, 1)
	testing.expect_value(t, gs.pawns[1].body.position, [3]f32{5, 3, 0})
}

@(test)
test_rewind_restores_crouch_hull :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)

	// crouching back then: the eye-height ray sails over the short hull
	gs.pawns[1].body.height = CROUCH_HEIGHT
	hist: Lag_History
	lag_history_record(&hist, &gs, 10)
	gs.pawns[1].body.height = PLAYER_HEIGHT

	rw, ok := lag_comp_begin(&hist, &gs, 10, 0)
	testing.expect(t, ok)
	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT)
	lag_comp_end(&gs, &rw)

	testing.expect_value(t, ev.shot.pawn, -1)
	testing.expect_value(t, gs.pawns[1].body.height, f32(PLAYER_HEIGHT))
}

@(test)
test_history_rejects_missing_ticks :: proc(t: ^testing.T) {
	gs := lag_range()
	defer destroy_lag_range(&gs)

	hist: Lag_History
	for tick in u32(1) ..= 70 {
		lag_history_record(&hist, &gs, tick)
	}

	testing.expect(t, lag_history_has(&hist, 70))
	testing.expect(t, lag_history_has(&hist, 7))
	testing.expect(t, !lag_history_has(&hist, 3)) // evicted by tick 67
	testing.expect(t, !lag_history_has(&hist, 0))

	_, ok := lag_comp_begin(&hist, &gs, 3, 0)
	testing.expect(t, !ok)
}
