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

	// shooter at the origin looking east, target five metres down the ray;
	// the shooter carries the ak so the range tests fire a real rifle
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
	testing.expect_value(
		t,
		gs.pawns[0].weapon.ammo[WEAPON_AK].mag,
		WEAPONS[WEAPON_AK].mag_size - 1,
	)
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
	gs.pawns[1].health = WEAPONS[WEAPON_AK].damage // exactly one rifle hit

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT)

	testing.expect(t, ev.killed)
	testing.expect(t, !gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[0].kills, 1)
}

@(test)
test_loadout_team_restriction :: proc(t: ^testing.T) {
	// the m4 is CT only: a T request falls back to no primary, the rest holds
	l := validate_loadout({primary = WEAPON_M4, secondary = WEAPON_GLOCK, armor = true}, .T)
	testing.expect_value(t, l.primary, i8(-1))
	testing.expect_value(t, l.secondary, i8(WEAPON_GLOCK))
	testing.expect(t, l.armor)

	l = validate_loadout({primary = WEAPON_AWP, secondary = WEAPON_USP, armor = false}, .CT)
	testing.expect_value(t, l.primary, i8(WEAPON_AWP))
	testing.expect_value(t, l.secondary, i8(WEAPON_USP))
}

@(test)
test_loadout_slot_lookup :: proc(t: ^testing.T) {
	l := default_loadout(.T)
	testing.expect_value(t, loadout_weapon_in_slot(l, 0), -1)
	testing.expect_value(t, loadout_weapon_in_slot(l, 1), WEAPON_GLOCK)
	testing.expect_value(t, loadout_weapon_in_slot(l, 2), WEAPON_KNIFE)

	// a slot-switch request for the empty primary does nothing
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].loadout = l
	gs.pawns[0].weapon.index = WEAPON_GLOCK
	input := Pawn_Input {
		weapon_slot = 0,
	}
	_ = tick_pawn_weapon(&gs, 0, input, TICK_DT)
	testing.expect_value(t, gs.pawns[0].weapon.index, WEAPON_GLOCK)
}

@(test)
test_awp_one_shot_through_full_armor :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].loadout = {
		primary   = WEAPON_AWP,
		secondary = WEAPON_GLOCK,
	}
	gs.pawns[0].weapon.index = WEAPON_AWP

	// full health, full vest -- the one-shot the table's damage is chosen for
	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT)
	testing.expect(t, ev.killed)
	testing.expect(t, !gs.pawns[1].alive)
}

@(test)
test_loadout_held_after_buy :: proc(t: ^testing.T) {
	// a bought primary goes into the hand
	before := default_loadout(.T)
	after := before
	after.primary = WEAPON_AK
	testing.expect_value(t, loadout_held_after_buy(before, after, WEAPON_KNIFE), WEAPON_AK)

	// an armor-only change keeps the hand
	before = after
	after.armor = true
	testing.expect_value(t, loadout_held_after_buy(before, after, WEAPON_KNIFE), WEAPON_KNIFE)
}
