package game

import "../physics"
import "core:testing"

// A grenade's landing spot is the one thing players practise for months, so
// the arc has to be a pure function of the throw -- same yaw, same pitch, same
// mode, same place, on the server and on every client.

@(private = "file")
make_world :: proc(walls: ..physics.Aabb) -> (gs: Game_State) {
	boxes := make([]physics.Aabb, 1 + len(walls))
	boxes[0] = {
		min = {-60, -60, -1},
		max = {60, 60, 0},
	}
	for w, i in walls do boxes[1 + i] = w
	gs.collision = boxes
	gs.grid = physics.grid_build(gs.collision)
	return
}

@(private = "file")
destroy_world :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

// Runs the world until something goes off, and reports it.
@(private = "file")
run_until_detonation :: proc(gs: ^Game_State, max_seconds: f32) -> (d: Detonation, ok: bool) {
	steps := int(max_seconds * TICK_RATE)
	for _ in 0 ..< steps {
		ev := tick_projectiles(gs, TICK_DT)
		if ev.count > 0 do return ev.items[0], true
	}
	return {}, false
}

@(test)
test_he_detonates_on_its_fuse :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	velocity := throw_velocity(0, 0, .Long, {})
	testing.expect(t, spawn_projectile(&gs, .He, 0, .T, {0, 0, 1.6}, velocity))

	// Count the ticks to the bang and compare against the spec's fuse.
	ticks := 0
	fired := false
	for _ in 0 ..< int(5 * TICK_RATE) {
		ticks += 1
		ev := tick_projectiles(&gs, TICK_DT)
		if ev.count > 0 {
			fired = true
			break
		}
	}
	testing.expect(t, fired, "the fuse never ran out")
	expected := int(GRENADES[.He].fuse * TICK_RATE)
	testing.expectf(t, abs(ticks - expected) <= 1, "went off after {} ticks, wanted ~{}", ticks, expected)
}

// Smoke has no fuse at all: it blooms where it stops, which is what makes a
// smoke thrown into a corner land in that corner.
@(test)
test_smoke_detonates_where_it_settles :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	velocity := throw_velocity(0, 0, .Short, {})
	testing.expect(t, spawn_projectile(&gs, .Smoke, 0, .T, {0, 0, 1.6}, velocity))

	d, ok := run_until_detonation(&gs, 10)
	testing.expect(t, ok, "the smoke never settled")
	testing.expect_value(t, d.kind, Grenade_Kind.Smoke)
	// On the floor it came to rest on, not in the air where it was thrown.
	testing.expectf(t, d.position.z < 0.5, "settled at z {}, expected floor level", d.position.z)
	testing.expectf(t, d.position.x > 0.5, "never travelled: x {}", d.position.x)
}

// The property the wire rests on. Two worlds, identical throws, identical
// landing spot down to the bit.
@(test)
test_throws_are_deterministic :: proc(t: ^testing.T) {
	wall := physics.Aabb {
		min = {6, -10, 0},
		max = {6.5, 10, 4},
	}
	a := make_world(wall)
	defer destroy_world(&a)
	b := make_world(wall)
	defer destroy_world(&b)

	// Aimed at the wall so the arc includes a bounce, which is where a
	// divergence would show up first.
	velocity := throw_velocity(12, -3, .Long, {1, 0.5, 0})
	spawn_projectile(&a, .Smoke, 0, .T, {0, 0, 1.6}, velocity)
	spawn_projectile(&b, .Smoke, 0, .T, {0, 0, 1.6}, velocity)

	da, oka := run_until_detonation(&a, 12)
	db, okb := run_until_detonation(&b, 12)

	testing.expect(t, oka && okb)
	testing.expect_value(t, da.position.x, db.position.x)
	testing.expect_value(t, da.position.y, db.position.y)
	testing.expect_value(t, da.position.z, db.position.z)
}

@(test)
test_throw_modes_reach_different_distances :: proc(t: ^testing.T) {
	distances: [Throw_Mode]f32
	for mode in Throw_Mode {
		gs := make_world()
		defer destroy_world(&gs)

		velocity := throw_velocity(0, 0, mode, {})
		spawn_projectile(&gs, .Smoke, 0, .T, {0, 0, 1.6}, velocity)
		d, ok := run_until_detonation(&gs, 12)
		testing.expectf(t, ok, "{} throw never settled", mode)
		distances[mode] = d.position.x
	}

	testing.expectf(
		t,
		distances[.Long] > distances[.Medium],
		"long ({}) must outreach medium ({})",
		distances[.Long],
		distances[.Medium],
	)
	testing.expectf(
		t,
		distances[.Medium] > distances[.Short],
		"medium ({}) must outreach short ({})",
		distances[.Medium],
		distances[.Short],
	)
}

// Running forward throws further than standing still. It is what makes a
// run-up smoke worth practising.
@(test)
test_movement_carries_into_the_throw :: proc(t: ^testing.T) {
	still := make_world()
	defer destroy_world(&still)
	running := make_world()
	defer destroy_world(&running)

	spawn_projectile(&still, .Smoke, 0, .T, {0, 0, 1.6}, throw_velocity(0, 0, .Long, {}))
	spawn_projectile(
		&running,
		.Smoke,
		0,
		.T,
		{0, 0, 1.6},
		throw_velocity(0, 0, .Long, {WALK_SPEED, 0, 0}),
	)

	a, oka := run_until_detonation(&still, 12)
	b, okb := run_until_detonation(&running, 12)
	testing.expect(t, oka && okb)
	testing.expectf(t, b.position.x > a.position.x, "run-up {} did not beat standing {}", b.position.x, a.position.x)
}

// The pool is finite and the failure has to be visible: a throw that cannot
// fit must be refused, not silently swallow the grenade.
@(test)
test_projectile_pool_is_bounded :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	for i in 0 ..< MAX_PROJECTILES {
		testing.expectf(
			t,
			spawn_projectile(&gs, .He, 0, .T, {0, 0, 1.6}, {}),
			"pool refused slot {} of {}",
			i,
			MAX_PROJECTILES,
		)
	}
	testing.expect(t, !spawn_projectile(&gs, .He, 0, .T, {0, 0, 1.6}, {}), "the pool must report being full")
}

// Nothing may stay in the world forever, however it is wedged.
@(test)
test_projectiles_always_leave_the_world :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	// A smoke on a slope can creep instead of settling; the age backstop is
	// what guarantees it still goes off.
	spawn_projectile(&gs, .Smoke, 0, .T, {0, 0, 1.6}, {})
	_, ok := run_until_detonation(&gs, PROJECTILE_MAX_LIFE + 1)
	testing.expect(t, ok)

	for &p in gs.projectiles {
		testing.expect(t, !p.active, "a projectile outlived its detonation")
	}
}

@(test)
test_grenade_team_rules :: proc(t: ^testing.T) {
	// The molotov is the one asymmetric buy, as in counter-strike.
	testing.expect(t, grenade_allowed(.Molotov, .T))
	testing.expect(t, !grenade_allowed(.Molotov, .CT))

	for kind in ([?]Grenade_Kind{.He, .Flash, .Smoke}) {
		testing.expectf(t, grenade_allowed(kind, .T), "{} must be available to T", kind)
		testing.expectf(t, grenade_allowed(kind, .CT), "{} must be available to CT", kind)
	}
}

@(test)
test_explosion_falloff :: proc(t: ^testing.T) {
	testing.expect_value(t, explosion_damage(100, 0, 10), 100)
	testing.expect_value(t, explosion_damage(100, 10, 10), 0)
	testing.expect_value(t, explosion_damage(100, 20, 10), 0)
	testing.expect_value(t, explosion_damage(100, 5, 10), 50)

	// Same shape as the bomb's, which is the point of sharing it.
	testing.expect_value(
		t,
		explosion_damage(BOMB_DAMAGE_MAX, 0, BOMB_DAMAGE_RADIUS),
		bomb_explosion_damage(0),
	)
	testing.expect_value(
		t,
		explosion_damage(BOMB_DAMAGE_MAX, 7, BOMB_DAMAGE_RADIUS),
		bomb_explosion_damage(7),
	)
}

// A blast does not go through a wall. Shares the sight test with fog of war,
// so a wall that hides you also shields you.
@(test)
test_explosions_respect_walls :: proc(t: ^testing.T) {
	wall := physics.Aabb {
		min = {2, -10, 0},
		max = {2.5, 10, 5},
	}
	gs := make_world(wall)
	defer destroy_world(&gs)

	centre := [3]f32{0, 0, 1}
	testing.expect(t, explosion_reaches(&gs, centre, {1, 0, 1}), "same side of the wall")
	testing.expect(t, !explosion_reaches(&gs, centre, {5, 0, 1}), "the wall must shield")
}
