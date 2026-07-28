package game

import "../physics"
import "core:math/rand"
import "core:testing"

// The seeded generator and the burst track under the microscope. Spray plus
// lag compensation needs no test of its own: the rewind touches victims'
// hulls only, never the shooter's Pawn_Weapon, so the pattern cannot drift
// under it.

@(test)
test_spray_shot0_is_the_aim :: proc(t: ^testing.T) {
	// The laser guarantee, mirroring pellet_dir's index 0: shot 0 of any burst
	// is the aim itself, for every weapon and any seed.
	for weapon in WEAPONS {
		track: Spray_Track
		off := spray_track_shot(&track, weapon.spray, weapon.mag_size, 0xDEAD_BEEF)
		testing.expect_value(t, off, [2]f32{0, 0})
	}
}

@(test)
test_spray_params_sane :: proc(t: ^testing.T) {
	for weapon in WEAPONS {
		par := weapon.spray
		if par.climb_shots == 0 {
			// no pattern at all -- the whole spec stays zeroed
			testing.expect_value(t, par, Spray_Params{})
			continue
		}
		// the deterministic prefix ends inside the climb, the climb inside
		// the magazine, and the zigzag inside the walk's bound
		testing.expect(t, par.det_shots <= par.climb_shots)
		testing.expect(t, par.climb_shots < weapon.mag_size)
		testing.expect(t, par.det_yaw < par.yaw_sway)
		// full-rate fire must sit inside the grace window, or a held trigger
		// would decay its own burst mid-magazine
		testing.expect(t, par.grace >= weapon.fire_interval)
		testing.expect(t, par.climb_pitch > 0 && par.climb_pitch <= 8)
		testing.expect(t, par.yaw_sway <= 4)
	}
}

// ------------------------------------------------------------ the generator

@(test)
test_spray_gen_deterministic :: proc(t: ^testing.T) {
	a, b: [SPRAY_MAX_POINTS][2]f32
	par := WEAPONS[WEAPON_AK].spray
	spray_build_points(par, 0xDEAD_BEEF, &a)
	spray_build_points(par, 0xDEAD_BEEF, &b)
	testing.expect_value(t, a, b)
}

@(test)
test_spray_gen_prefix_seed_independent :: proc(t: ^testing.T) {
	// the deterministic prefix is identical across seeds; past it, seeds must
	// actually diverge somewhere or the whole point is lost
	a, b: [SPRAY_MAX_POINTS][2]f32
	par := WEAPONS[WEAPON_AK].spray
	for seed in u32(1) ..= 16 {
		spray_build_points(par, seed, &a)
		spray_build_points(par, seed * 7919, &b)
		for k in 0 ..< par.det_shots {
			testing.expect_value(t, a[k], b[k])
		}
		diverged := false
		for k in par.det_shots ..< SPRAY_MAX_POINTS {
			if a[k] != b[k] do diverged = true
		}
		testing.expect(t, diverged)
	}
}

@(test)
test_spray_gen_bounds :: proc(t: ^testing.T) {
	// every weapon with a pattern, over many seeds: yaw inside the sway
	// bound, pitch inside the climb, and the climb never dips -- pulling
	// down is always the right correction
	points: [SPRAY_MAX_POINTS][2]f32
	for weapon in WEAPONS {
		par := weapon.spray
		if par.climb_shots == 0 do continue
		for seed in u32(0) ..< 64 {
			spray_build_points(par, seed, &points)
			testing.expect_value(t, points[0], [2]f32{0, 0})
			for off in points {
				testing.expect(t, abs(off.x) <= par.yaw_sway)
				testing.expect(t, off.y >= 0 && off.y <= par.climb_pitch + par.pitch_jitter)
			}
			for k in 1 ..= par.climb_shots {
				testing.expect(t, points[k].y > points[k - 1].y)
			}
		}
	}
}

@(test)
test_spray_point_at_lerps :: proc(t: ^testing.T) {
	points: [SPRAY_MAX_POINTS][2]f32
	ak := WEAPONS[WEAPON_AK]
	spray_build_points(ak.spray, 42, &points)

	testing.expect_value(t, spray_point_at(&points, 0, ak.mag_size), [2]f32{0, 0})
	testing.expect_value(t, spray_point_at(&points, -1, ak.mag_size), [2]f32{0, 0})

	mid := (points[2] + points[3]) * 0.5
	got := spray_point_at(&points, 2.5, ak.mag_size)
	testing.expect(t, abs(got.x - mid.x) < 1e-5 && abs(got.y - mid.y) < 1e-5)

	// past the magazine the last point holds
	last := points[ak.mag_size - 1]
	testing.expect_value(t, spray_point_at(&points, 1000, ak.mag_size), last)
}

// ------------------------------------------------------------------ the track

@(test)
test_spray_track_shot_advances :: proc(t: ^testing.T) {
	ak := WEAPONS[WEAPON_AK]
	track: Spray_Track
	off := spray_track_shot(&track, ak.spray, ak.mag_size, 7)
	testing.expect_value(t, off, [2]f32{0, 0}) // pre-increment sample: the laser
	testing.expect_value(t, track.progress, f32(1))
	testing.expect_value(t, track.cool, f32(0))
	testing.expect_value(t, track.seed, u32(7))

	// mid-burst the fresh seed is not consumed
	_ = spray_track_shot(&track, ak.spray, ak.mag_size, 999)
	testing.expect_value(t, track.progress, f32(2))
	testing.expect_value(t, track.seed, u32(7))

	// depth clamps at the magazine
	for _ in 0 ..< 100 {
		_ = spray_track_shot(&track, ak.spray, ak.mag_size, 999)
	}
	testing.expect_value(t, track.progress, f32(ak.mag_size))
}

@(test)
test_spray_track_grace_holds :: proc(t: ^testing.T) {
	ak := WEAPONS[WEAPON_AK]
	track: Spray_Track
	_ = spray_track_shot(&track, ak.spray, ak.mag_size, 1)

	// full-rate fire sits inside the grace window: no decay, integer depth
	for _ in 0 ..< 9 { // 9 ticks = 0.14 s < grace 0.15
		spray_track_decay(&track, ak.spray, TICK_DT)
	}
	testing.expect_value(t, track.progress, f32(1))

	spray_track_decay(&track, ak.spray, TICK_DT) // 0.156 s: past grace
	testing.expect(t, track.progress < 1)
}

@(test)
test_spray_track_feathers_and_zeroes :: proc(t: ^testing.T) {
	ak := WEAPONS[WEAPON_AK]
	track: Spray_Track
	for _ in 0 ..< 5 {
		_ = spray_track_shot(&track, ak.spray, ak.mag_size, 3)
	}
	testing.expect_value(t, track.progress, f32(5))

	// a 0.35 s pause pays back part of the burst, not all of it
	elapsed := f32(0)
	for elapsed < 0.35 {
		spray_track_decay(&track, ak.spray, TICK_DT)
		elapsed += TICK_DT
	}
	testing.expect(t, track.progress > 0 && track.progress < 5)

	// and a long one reaches an exact 0 -- the linear finisher guarantees it
	for elapsed < 3 {
		spray_track_decay(&track, ak.spray, TICK_DT)
		elapsed += TICK_DT
	}
	testing.expect_value(t, track.progress, f32(0))

	// a fresh pull after the cooloff rolls the new seed
	_ = spray_track_shot(&track, ak.spray, ak.mag_size, 77)
	testing.expect_value(t, track.seed, u32(77))
}

// ------------------------------------------------------- through fire control

@(private = "file")
spray_range :: proc(state: ^rand.Default_Random_State) -> (gs: Game_State) {
	gs.collision = make([]physics.Aabb, 1)
	gs.collision[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	gs.grid = physics.grid_build(gs.collision)
	// Pinned: burst-seed rolls draw from gs.rng even planted.
	gs.rng = rand.default_random_generator(state)

	// shooter at the origin looking east onto the chest of a target at 5 m
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
	gs.pawns[0].pitch = -5.2
	// On the floor: an airborne shooter would draw random spread on top.
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
destroy_spray_range :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(private = "file")
HOLD :: Pawn_Input {
	buttons     = {.Fire},
	weapon_slot = -1,
}

@(private = "file")
PULL :: Pawn_Input {
	buttons     = {.Fire_Pressed},
	weapon_slot = -1,
}

@(private = "file")
IDLE :: Pawn_Input {
	weapon_slot = -1,
}

@(test)
test_spray_walks_up_the_target :: proc(t: ^testing.T) {
	s := rand.create(11)
	gs := spray_range(&s)
	defer destroy_spray_range(&gs)
	gs.pawns[1].health = 10000 // nobody dies mid-measurement

	first_z, fourth_z: f32
	fired := 0
	for _ in 0 ..< 40 {
		ev := tick_pawn_weapon(&gs, 0, HOLD, TICK_DT, .Live)
		if !ev.fired do continue
		fired += 1
		if fired == 1 do first_z = ev.shots[0].point.z
		if fired == 4 {
			fourth_z = ev.shots[0].point.z
			break
		}
	}

	// point 3 of the climb sits ~1.7 degrees high: at 5 m that is well over
	// a decimetre
	testing.expect_value(t, fired, 4)
	testing.expect(t, fourth_z > first_z + 0.1)
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(4))
}

@(test)
test_spray_burst_decays_after_pause :: proc(t: ^testing.T) {
	s := rand.create(12)
	gs := spray_range(&s)
	defer destroy_spray_range(&gs)

	ev := tick_pawn_weapon(&gs, 0, PULL, TICK_DT, .Live)
	testing.expect(t, ev.fired)
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(1))

	// the grace window (0.15 s = 9.6 ticks) holds the depth exactly
	for _ in 0 ..< 9 {
		_ = tick_pawn_weapon(&gs, 0, IDLE, TICK_DT, .Live)
	}
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(1))

	// past it the depth slides down and reaches an exact 0
	for _ in 0 ..< 40 {
		_ = tick_pawn_weapon(&gs, 0, IDLE, TICK_DT, .Live)
	}
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(0))
}

@(test)
test_spray_feathering_pays_back_partially :: proc(t: ^testing.T) {
	s := rand.create(13)
	gs := spray_range(&s)
	defer destroy_spray_range(&gs)
	gs.pawns[1].health = 10000

	fired := 0
	for fired < 5 {
		ev := tick_pawn_weapon(&gs, 0, HOLD, TICK_DT, .Live)
		if ev.fired do fired += 1
	}
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(5))

	// a 0.35 s breather: part of the burst comes back, not all of it
	for _ in 0 ..< 23 {
		_ = tick_pawn_weapon(&gs, 0, IDLE, TICK_DT, .Live)
	}
	p := gs.pawns[0].weapon.spray.progress
	testing.expect(t, p > 0 && p < 5)
}

@(test)
test_spray_one_pull_one_step_with_pellets :: proc(t: ^testing.T) {
	s := rand.create(14)
	gs := spray_range(&s)
	defer destroy_spray_range(&gs)
	gs.pawns[0].loadout.primary = WEAPON_NOVA
	gs.pawns[0].weapon.index = WEAPON_NOVA

	ev := tick_pawn_weapon(&gs, 0, PULL, TICK_DT, .Live)

	// nine pellets fly, the burst advances once
	testing.expect_value(t, ev.shot_count, NOVA_PELLETS)
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(1))
}

@(test)
test_spray_resets_on_switch_and_reload :: proc(t: ^testing.T) {
	s := rand.create(15)
	gs := spray_range(&s)
	defer destroy_spray_range(&gs)
	w := &gs.pawns[0].weapon

	_ = tick_pawn_weapon(&gs, 0, PULL, TICK_DT, .Live)
	testing.expect_value(t, w.spray.progress, f32(1))
	select_pawn_weapon(w, WEAPON_GLOCK)
	testing.expect_value(t, w.spray.progress, f32(0))

	select_pawn_weapon(w, WEAPON_AK)
	w.cooldown = 0
	_ = tick_pawn_weapon(&gs, 0, PULL, TICK_DT, .Live)
	testing.expect_value(t, w.spray.progress, f32(1))
	testing.expect(t, start_pawn_reload(w))
	testing.expect_value(t, w.spray.progress, f32(0))
}

@(test)
test_spray_dry_fire_no_advance :: proc(t: ^testing.T) {
	s := rand.create(16)
	gs := spray_range(&s)
	defer destroy_spray_range(&gs)
	gs.pawns[0].weapon.ammo[WEAPON_AK].mag = 0

	ev := tick_pawn_weapon(&gs, 0, PULL, TICK_DT, .Live)

	// a click on an empty magazine is not a shot and not a burst
	testing.expect(t, ev.dry)
	testing.expect_value(t, gs.pawns[0].weapon.spray.progress, f32(0))
}

@(test)
test_spray_fire_deterministic :: proc(t: ^testing.T) {
	s1 := rand.create(99)
	s2 := rand.create(99)
	gs1 := spray_range(&s1)
	defer destroy_spray_range(&gs1)
	gs2 := spray_range(&s2)
	defer destroy_spray_range(&gs2)

	for _ in 0 ..< 30 {
		ev1 := tick_pawn_weapon(&gs1, 0, HOLD, TICK_DT, .Live)
		ev2 := tick_pawn_weapon(&gs2, 0, HOLD, TICK_DT, .Live)
		testing.expect(t, ev1 == ev2)
	}
	testing.expect_value(t, gs1.pawns[0].weapon.spray.progress, gs2.pawns[0].weapon.spray.progress)
	testing.expect_value(t, gs1.pawns[1].health, gs2.pawns[1].health)
}

@(test)
test_spray_bursts_differ_across_seeds :: proc(t: ^testing.T) {
	// two worlds with different rng seeds: identical through the prefix in
	// pattern terms would still differ via impact spread only past det_shots
	a, b: [SPRAY_MAX_POINTS][2]f32
	par := WEAPONS[WEAPON_AK].spray
	t1: Spray_Track
	t2: Spray_Track
	_ = spray_track_shot(&t1, par, 30, 100)
	_ = spray_track_shot(&t2, par, 30, 200)
	a = t1.points
	b = t2.points
	for k in 0 ..< par.det_shots {
		testing.expect_value(t, a[k], b[k])
	}
	diverged := false
	for k in par.det_shots ..< SPRAY_MAX_POINTS {
		if a[k] != b[k] do diverged = true
	}
	testing.expect(t, diverged)
}
