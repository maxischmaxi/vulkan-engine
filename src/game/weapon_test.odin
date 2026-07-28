package game

import "../physics"
import "core:testing"

// The server's fire path, end to end: a Fire button on the wire must become a
// trace, a hit and damage. This exists because the one link a headless test
// cannot see -- the client putting the button on the wire -- once shipped
// missing, and everything looked fine except that nothing ever died.

@(private = "file")
make_range :: proc() -> (gs: Game_State) {
	gs.collision = make([]physics.Aabb, 1)
	gs.collision[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	gs.grid = physics.grid_build(gs.collision)

	// shooter at the origin looking east, target five metres down the ray
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
	refill_pawn_ammo(&gs.pawns[0].weapon)
	init_pawn(&gs.pawns[1], {5, 0, 0}, 0)
	return
}

@(private = "file")
destroy_range :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(test)
test_fire_edge_damages_target :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT)

	testing.expect(t, ev.fired)
	testing.expect(t, ev.shot.hit)
	testing.expect_value(t, ev.shot.pawn, 1)
	testing.expect(t, gs.pawns[1].health < PAWN_MAX_HEALTH)
	testing.expect_value(t, gs.pawns[0].weapon.ammo[0].mag, WEAPONS[0].mag_size - 1)
}

@(test)
test_fire_held_automatic_fires :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)

	// the rifle is automatic: a held trigger with no edge must still fire
	input := Pawn_Input {
		buttons     = {.Fire},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT)
	testing.expect(t, ev.fired)

	// and the very next tick sits inside the fire interval
	ev = tick_pawn_weapon(&gs, 0, input, TICK_DT)
	testing.expect(t, !ev.fired)
}

@(test)
test_fire_kills_through_armor_math :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[1].armor = 0
	gs.pawns[1].health = WEAPONS[0].damage // exactly one rifle hit

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT)

	testing.expect(t, ev.killed)
	testing.expect(t, !gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[0].kills, 1)
}
