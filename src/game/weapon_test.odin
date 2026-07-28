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
	// The runner seeds this per test: burst starts roll their seed from it.
	gs.rng = context.random_generator

	// shooter at the origin looking east, target five metres down the ray;
	// the shooter carries the ak so the range tests fire a real rifle. Pitched
	// down onto the chest so the generic fire tests read the x1 zone -- the
	// eye-height ray would land in the head band and quadruple everything.
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
	gs.pawns[0].pitch = -5.2
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

@(test)
test_fire_edge_damages_target :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)

	testing.expect(t, ev.fired)
	testing.expect_value(t, ev.shot_count, 1)
	testing.expect(t, ev.shots[0].hit)
	testing.expect_value(t, ev.shots[0].pawn, 1)
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
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)
	testing.expect(t, ev.fired)

	// and the very next tick sits inside the fire interval
	ev = tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)
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
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)

	testing.expect_value(t, ev.victim_count, 1)
	testing.expect(t, ev.victims[0].killed)
	testing.expect(t, !gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[0].kills, 1)
}

@(test)
test_damage_pawn_armor_pen :: proc(t: ^testing.T) {
	p: Pawn

	// pen 0 keeps the classic split: 40 -> 20 absorbed, 20 taken
	init_pawn(&p, {0, 0, 0}, 0)
	_ = damage_pawn(&p, 40)
	testing.expect_value(t, p.health, 80)
	testing.expect_value(t, p.armor, 80)

	// the ak's pen 0.55: absorb int(40 * 0.5 * 0.45) = 9
	init_pawn(&p, {0, 0, 0}, 0)
	_ = damage_pawn(&p, 40, 0.55)
	testing.expect_value(t, p.health, 69)
	testing.expect_value(t, p.armor, 91)

	// pen 1: the vest sees nothing and wears not at all
	init_pawn(&p, {0, 0, 0}, 0)
	_ = damage_pawn(&p, 40, 1)
	testing.expect_value(t, p.health, 60)
	testing.expect_value(t, p.armor, 100)
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
	_ = tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)
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

	// full health, full vest -- the one-shot the table's damage is chosen for.
	// Scoped: an unzoomed awp pays a random hip-fire cone even planted.
	input := Pawn_Input {
		buttons     = {.Fire_Pressed, .Zoom},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)
	testing.expect_value(t, ev.victim_count, 1)
	testing.expect(t, ev.victims[0].killed)
	testing.expect(t, !gs.pawns[1].alive)
}

@(test)
test_ak_armored_headshot_one_shots :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].pitch = 0 // eye height: the head band

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)

	// 160 nominal, 36 to the vest at pen 0.55, 124 through: the one-tap
	testing.expect_value(t, ev.shots[0].group, Hit_Group.Head)
	testing.expect_value(t, ev.victim_count, 1)
	testing.expect(t, ev.victims[0].killed)
	testing.expect(t, !gs.pawns[1].alive)
}

@(test)
test_m4_armored_headshot_leaves_sliver :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].loadout = {
		primary   = WEAPON_M4,
		secondary = WEAPON_USP,
	}
	gs.pawns[0].weapon.index = WEAPON_M4
	gs.pawns[0].pitch = 0

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)

	// 140 nominal, 42 absorbed at pen 0.40: two hp short of the ak's one-tap
	testing.expect_value(t, ev.shots[0].group, Hit_Group.Head)
	testing.expect(t, !ev.victims[0].killed)
	testing.expect(t, gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[1].health, 2)
}

@(test)
test_awp_leg_shot_survives :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].loadout = {
		primary   = WEAPON_AWP,
		secondary = WEAPON_USP,
	}
	gs.pawns[0].weapon.index = WEAPON_AWP
	gs.pawns[0].pitch = -13.8 // down into the leg band

	input := Pawn_Input {
		buttons     = {.Fire_Pressed, .Zoom}, // scoped, so the shot is a laser
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)

	// 86 nominal, and no vest below the belt: the one shot the awp forgives
	testing.expect_value(t, ev.shots[0].group, Hit_Group.Legs)
	testing.expect(t, !ev.victims[0].killed)
	testing.expect(t, gs.pawns[1].alive)
	testing.expect_value(t, gs.pawns[1].health, 14)
	testing.expect_value(t, gs.pawns[1].armor, PAWN_MAX_ARMOR)
}

@(test)
test_knife_ignores_hit_zones :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	gs.pawns[0].weapon.index = WEAPON_KNIFE
	gs.pawns[0].pitch = 0
	gs.pawns[1].body.position = {1, 0, 0} // arm's length

	input := Pawn_Input {
		buttons     = {.Fire_Pressed},
		weapon_slot = -1,
	}
	ev := tick_pawn_weapon(&gs, 0, input, TICK_DT, .Live)

	// an eye-height stab lands in the head band but stays a knife: 55, not 220
	testing.expect_value(t, ev.victim_count, 1)
	testing.expect_value(t, ev.victims[0].nominal, 55)
	testing.expect_value(t, gs.pawns[1].health, 72)
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
