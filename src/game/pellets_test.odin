package game

import "../physics"
import "core:math"
import "core:math/linalg"
import "core:testing"

// The pellet pattern under the microscope: the same nine rays every pull, all
// inside the cone, single-ray weapons bit-identical to the pre-pellet code,
// and a blast that can hurt more than one pawn.

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

	// shooter at the origin looking east, armed with the shotgun
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
	// On the floor: pawn_move would set this before any server-side fire, and
	// an airborne shooter would draw random spread on top.
	gs.pawns[0].body.on_ground = true
	gs.pawns[0].loadout = {
		primary   = WEAPON_NOVA,
		secondary = WEAPON_GLOCK,
	}
	gs.pawns[0].weapon.index = WEAPON_NOVA
	refill_pawn_ammo(&gs.pawns[0].weapon)
	return
}

@(private = "file")
destroy_range :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(private = "file")
FIRE :: Pawn_Input {
	buttons     = {.Fire_Pressed},
	weapon_slot = -1,
}

@(test)
test_pellet_dir_index0_is_forward :: proc(t: ^testing.T) {
	// The bit-identity guarantee: the center pellet and any zero-spread ray
	// are exactly view_forward, so single-ray weapons trace as they always did.
	for angles in ([][2]f32{{0, 0}, {90, 30}, {-135, -60}, {17.5, 89}}) {
		forward := view_forward(angles.x, angles.y)
		testing.expect_value(t, pellet_dir(angles.x, angles.y, 0, 0.0675), forward)
		for i in 0 ..< MAX_PELLETS {
			testing.expect_value(t, pellet_dir(angles.x, angles.y, i, 0), forward)
		}
	}
}

@(test)
test_pellet_cone_bound :: proc(t: ^testing.T) {
	spread := f32(0.0675)
	limit := 1 / math.sqrt(1 + spread * spread) // cos(atan(spread))
	for yaw in ([]f32{0, 90, -135}) {
		for pitch in ([]f32{-60, 0, 60}) {
			forward := view_forward(yaw, pitch)
			for i in 0 ..< MAX_PELLETS {
				dir := pellet_dir(yaw, pitch, i, spread)
				testing.expect(t, linalg.dot(dir, forward) >= limit - 1e-4)
				testing.expect(t, abs(linalg.length(dir) - 1) < 1e-4)
			}
		}
	}
}

@(test)
test_pellet_table_sane :: proc(t: ^testing.T) {
	// The compile-time assert only covers the nova constant; the table itself
	// is a runtime value, so it gets swept here.
	for weapon in WEAPONS {
		testing.expect(t, weapon.pellets <= MAX_PELLETS)
		testing.expect(t, weapon.spread >= 0)
		if weapon.pellets > 1 do testing.expect(t, !weapon.melee)
	}
}

@(test)
test_nova_fire_deterministic :: proc(t: ^testing.T) {
	gs1 := make_range()
	defer destroy_range(&gs1)
	gs2 := make_range()
	defer destroy_range(&gs2)
	init_pawn(&gs1.pawns[1], {3, 0, 0}, 0)
	init_pawn(&gs2.pawns[1], {3, 0, 0}, 0)

	ev1 := tick_pawn_weapon(&gs1, 0, FIRE, TICK_DT, .Live)
	ev2 := tick_pawn_weapon(&gs2, 0, FIRE, TICK_DT, .Live)

	testing.expect(t, ev1 == ev2)
	testing.expect_value(
		t,
		gs1.pawns[0].weapon.ammo[WEAPON_NOVA].mag,
		WEAPONS[WEAPON_NOVA].mag_size - 1,
	)
	testing.expect_value(
		t,
		gs2.pawns[0].weapon.ammo[WEAPON_NOVA].mag,
		WEAPONS[WEAPON_NOVA].mag_size - 1,
	)
}

@(test)
test_nova_point_blank_aggregates_one_victim :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	// Health inflated so no mid-blast death hides pellets; pitched onto the
	// chest so all nine pellets land in the same x1 zone (z 1.12..1.38 of 1.8)
	// and the nominal sum stays the plain per-pellet damage.
	init_pawn(&gs.pawns[1], {3, 0, 0}, 0)
	gs.pawns[0].pitch = -8.4
	gs.pawns[1].armor = 0
	gs.pawns[1].health = 1000

	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Live)

	testing.expect_value(t, ev.shot_count, NOVA_PELLETS)
	for shot in ev.shots[:ev.shot_count] {
		testing.expect(t, shot.hit)
		testing.expect_value(t, shot.pawn, 1)
	}
	testing.expect_value(t, ev.victim_count, 1)
	testing.expect_value(t, ev.victims[0].nominal, NOVA_PELLETS * WEAPONS[WEAPON_NOVA].damage)
	testing.expect(t, !ev.victims[0].killed)
	testing.expect_value(t, gs.pawns[1].health, 1000 - NOVA_PELLETS * WEAPONS[WEAPON_NOVA].damage)
}

@(test)
test_nova_blast_straddles_two_victims :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	// Two hulls flanking the aim point at 4 m: the axis and lower-diagonal
	// pellets land one per side, the center passes through the gap, the upper
	// diagonals clear the heads. Any single pellet kills.
	init_pawn(&gs.pawns[1], {4, 0.35, 0}, 0)
	init_pawn(&gs.pawns[2], {4, -0.35, 0}, 0)
	for i in 1 ..= 2 {
		gs.pawns[i].armor = 0
		gs.pawns[i].health = WEAPONS[WEAPON_NOVA].damage
	}

	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Live)

	testing.expect_value(t, ev.victim_count, 2)
	for v in ev.victims[:ev.victim_count] {
		testing.expect(t, v.killed)
	}
	testing.expect(t, !gs.pawns[1].alive)
	testing.expect(t, !gs.pawns[2].alive)
	testing.expect_value(t, gs.pawns[0].kills, 2)
}

@(test)
test_nova_corpse_transparent_mid_blast :: proc(t: ^testing.T) {
	gs := make_range()
	defer destroy_range(&gs)
	// Dies to the fourth hitting pellet (all in the chest band); the rest of
	// the blast passes through the corpse instead of pounding it further.
	init_pawn(&gs.pawns[1], {3, 0, 0}, 0)
	gs.pawns[0].pitch = -8.4
	gs.pawns[1].armor = 0
	gs.pawns[1].health = 100

	ev := tick_pawn_weapon(&gs, 0, FIRE, TICK_DT, .Live)

	testing.expect_value(t, ev.victim_count, 1)
	testing.expect(t, ev.victims[0].killed)
	testing.expect_value(t, ev.victims[0].nominal, 4 * WEAPONS[WEAPON_NOVA].damage)
	for shot in ev.shots[4:ev.shot_count] {
		testing.expect_value(t, shot.pawn, -1)
	}
}
