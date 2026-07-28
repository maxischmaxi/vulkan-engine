package game

import "../physics"
import "core:math/rand"
import "core:testing"

// The stance math is pure; the draws are pinned by seeding. What cannot be
// tested here -- that online only the server draws -- is architecture: the
// client never runs tick_pawn_weapon for itself.

@(private = "file")
standing_pawn :: proc() -> (p: Pawn) {
	init_pawn(&p, {0, 0, 0}, 0)
	p.body.on_ground = true
	return
}

@(test)
test_inaccuracy_planted_is_zero :: proc(t: ^testing.T) {
	p := standing_pawn()
	for weapon in WEAPONS {
		if weapon.zoom_fov > 0 do continue // scoped weapons pay a hip-fire tax
		testing.expect_value(t, inaccuracy_degrees(weapon, p, false, 0), f32(0))
	}
	// the awp planted and looking through its scope is a laser too
	testing.expect_value(t, inaccuracy_degrees(WEAPONS[WEAPON_AWP], p, true, 0), f32(0))
}

@(test)
test_inaccuracy_stance_penalties :: proc(t: ^testing.T) {
	ak := WEAPONS[WEAPON_AK]
	p := standing_pawn()

	p.body.velocity = {WALK_SPEED, 0, 0}
	testing.expect_value(t, inaccuracy_degrees(ak, p, false, 0), ak.inacc_move)

	// quadratic in speed: half pace costs a quarter
	p.body.velocity = {WALK_SPEED / 2, 0, 0}
	testing.expect_value(t, inaccuracy_degrees(ak, p, false, 0), ak.inacc_move * 0.25)

	// crouching steadies the move penalty
	p.crouching = true
	testing.expect_value(
		t,
		inaccuracy_degrees(ak, p, false, 0),
		ak.inacc_move * 0.25 * CROUCH_INACC_SCALE,
	)

	// air time stacks on top of the feet
	p.crouching = false
	p.body.on_ground = false
	testing.expect_value(t, inaccuracy_degrees(ak, p, false, 0), ak.inacc_move * 0.25 + ak.inacc_air)

	// a hip-fired awp pays even planted
	awp := WEAPONS[WEAPON_AWP]
	q := standing_pawn()
	testing.expect_value(t, inaccuracy_degrees(awp, q, false, 0), awp.inacc_unscoped)
}

@(test)
test_inaccuracy_fire_bloom :: proc(t: ^testing.T) {
	ak := WEAPONS[WEAPON_AK]
	p := standing_pawn()

	// the first shot of a burst stays exact; depth opens the cone linearly
	testing.expect_value(t, inaccuracy_degrees(ak, p, false, 0), f32(0))
	testing.expect_value(t, inaccuracy_degrees(ak, p, false, 4), ak.inacc_fire * 4)
	// and stops opening past the cap
	testing.expect_value(
		t,
		inaccuracy_degrees(ak, p, false, 30),
		ak.inacc_fire * FIRE_INACC_CAP_SHOTS,
	)
}

@(test)
test_inaccuracy_offset_draws :: proc(t: ^testing.T) {
	state := rand.create(42)
	g := rand.default_random_generator(&state)

	// a zero cone draws nothing: planted fire never touches the rng
	testing.expect_value(t, inaccuracy_offset(g, 0), [2]f32{0, 0})

	prev: [2]f32
	for i in 0 ..< 100 {
		o := inaccuracy_offset(g, 2.5)
		testing.expect(t, o.x * o.x + o.y * o.y <= 2.5 * 2.5 + 1e-4)
		if i > 0 do testing.expect(t, o != prev)
		prev = o
	}
}

@(test)
test_inaccuracy_offset_replays_per_seed :: proc(t: ^testing.T) {
	s1 := rand.create(7)
	s2 := rand.create(7)
	g1 := rand.default_random_generator(&s1)
	g2 := rand.default_random_generator(&s2)
	for _ in 0 ..< 32 {
		testing.expect_value(t, inaccuracy_offset(g1, 3), inaccuracy_offset(g2, 3))
	}
}

@(private = "file")
moving_range :: proc(state: ^rand.Default_Random_State) -> (gs: Game_State) {
	gs.collision = make([]physics.Aabb, 1)
	gs.collision[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
	}
	gs.grid = physics.grid_build(gs.collision)
	gs.rng = rand.default_random_generator(state)

	// an ak shooter at full pace, aimed at the chest of a target at 5 m
	init_pawn(&gs.pawns[0], {0, 0, 0}, 0)
	gs.pawns[0].pitch = -5.2
	gs.pawns[0].body.on_ground = true
	gs.pawns[0].body.velocity = {0, WALK_SPEED, 0} // strafing, not closing in
	gs.pawns[0].loadout = {
		primary   = WEAPON_AK,
		secondary = WEAPON_GLOCK,
	}
	gs.pawns[0].weapon.index = WEAPON_AK
	refill_pawn_ammo(&gs.pawns[0].weapon)
	init_pawn(&gs.pawns[1], {5, 0, 0}, 0)
	gs.pawns[1].health = 10000
	return
}

@(private = "file")
destroy_moving_range :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(test)
test_moving_fire_jitters_and_replays :: proc(t: ^testing.T) {
	s1 := rand.create(99)
	s2 := rand.create(99)
	gs1 := moving_range(&s1)
	defer destroy_moving_range(&gs1)
	gs2 := moving_range(&s2)
	defer destroy_moving_range(&gs2)

	// the planted reference ray, no rng involved
	planted := trace_shot(&gs1, 0, eye_position(gs1.pawns[0]), pellet_dir(0, -5.2, 0, 0), 200)

	hold := Pawn_Input {
		buttons     = {.Fire},
		weapon_slot = -1,
	}
	jittered := false
	fired := 0
	for _ in 0 ..< 60 {
		ev1 := tick_pawn_weapon(&gs1, 0, hold, TICK_DT, .Live)
		ev2 := tick_pawn_weapon(&gs2, 0, hold, TICK_DT, .Live)
		// same seed, same stance: the servers of two identical worlds agree
		testing.expect(t, ev1 == ev2)
		if !ev1.fired do continue
		fired += 1
		if abs(ev1.shots[0].point.z - planted.point.z) > 0.01 do jittered = true
	}

	testing.expect(t, fired >= 8)
	testing.expect(t, jittered)
}
