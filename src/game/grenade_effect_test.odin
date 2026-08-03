package game

import "../physics"
import "core:testing"

// What each grenade does. The numbers here are balance, so the tests pin the
// shape of the rules rather than exact values: a blast falls off with distance
// and stops at walls, a flash cares where you were looking, fire burns while
// you stand in it.

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

@(private = "file")
place :: proc(gs: ^Game_State, id: int, position: [3]f32) -> ^Pawn {
	p := &gs.pawns[id]
	init_pawn(p, position, 0)
	return p
}

// ------------------------------------------------------------------ he

@(test)
test_he_falls_off_with_distance :: proc(t: ^testing.T) {
	testing.expect_value(t, he_damage_at(0), HE_MAX_DAMAGE)
	testing.expect_value(t, he_damage_at(HE_RADIUS), 0)
	testing.expect_value(t, he_damage_at(HE_RADIUS + 5), 0)

	near := he_damage_at(2)
	far := he_damage_at(6)
	testing.expect(t, near > far, "closer must hurt more")
	testing.expect(t, far > 0, "inside the radius must hurt at all")
}

@(test)
test_he_blast_reaches_the_exposed :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	place(&gs, 0, {0, 0, 0}) // at the centre
	place(&gs, 1, {4, 0, 0}) // nearby
	place(&gs, 2, {40, 0, 0}) // far outside

	blast := he_blast(&gs, {0, 0, 1})
	testing.expect_value(t, blast.count, 2)

	// Sorted by pawn id as the loop walks them, so the centre comes first and
	// must have taken the most.
	testing.expect_value(t, blast.items[0].pawn, 0)
	testing.expect_value(t, blast.items[1].pawn, 1)
	testing.expect(t, blast.items[0].amount > blast.items[1].amount)
	testing.expect_value(t, blast.items[0].armor_pen, HE_ARMOR_PEN)
}

// A wall shields. Same sight test fog of war uses, so cover that hides you is
// cover that protects you.
@(test)
test_he_does_not_go_through_walls :: proc(t: ^testing.T) {
	wall := physics.Aabb {
		min = {2, -10, 0},
		max = {2.5, 10, 5},
	}
	gs := make_world(wall)
	defer destroy_world(&gs)

	place(&gs, 0, {1, 0, 0}) // blast side
	place(&gs, 1, {4, 0, 0}) // behind the wall, well inside the radius

	blast := he_blast(&gs, {0, 0, 1})
	testing.expect_value(t, blast.count, 1)
	testing.expect_value(t, blast.items[0].pawn, 0)
}

// A grenade at your own feet hurts you. Anything else would make the HE a
// free tool at close range.
@(test)
test_he_hurts_the_thrower :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	p := place(&gs, 0, {0, 0, 0})
	p.team = .T

	blast := he_blast(&gs, p.body.position + {0, 0, 0.5})
	testing.expect_value(t, blast.count, 1)
	testing.expect(t, blast.items[0].amount > 50, "point blank must be severe")
}

// ------------------------------------------------------------------ flash

@(test)
test_flash_is_worst_looking_straight_at_it :: proc(t: ^testing.T) {
	eye := [3]f32{0, 0, 1.65}
	flash := [3]f32{3, 0, 1.65}

	facing := flash_duration(eye, {1, 0, 0}, flash, false)
	sideways := flash_duration(eye, {0, 1, 0}, flash, false)
	away := flash_duration(eye, {-1, 0, 0}, flash, false)

	testing.expect(t, facing > sideways, "straight on must beat peripheral")
	testing.expect(t, sideways > away, "peripheral must beat facing away")
	testing.expect(t, away >= FLASH_MIN_DURATION, "even behind you it robs a moment")
	testing.expect(t, facing <= FLASH_MAX_DURATION)
}

@(test)
test_flash_falls_off_with_distance :: proc(t: ^testing.T) {
	eye := [3]f32{0, 0, 1.65}
	near := flash_duration(eye, {1, 0, 0}, {2, 0, 1.65}, false)
	far := flash_duration(eye, {1, 0, 0}, {11, 0, 1.65}, false)
	outside := flash_duration(eye, {1, 0, 0}, {FLASH_RADIUS + 1, 0, 1.65}, false)

	testing.expect(t, near > far)
	testing.expect_value(t, outside, 0)
}

// The rule the whole grenade hangs on: a wall between you and the pop means
// nothing happens at all.
@(test)
test_flash_behind_a_wall_does_nothing :: proc(t: ^testing.T) {
	eye := [3]f32{0, 0, 1.65}
	testing.expect_value(t, flash_duration(eye, {1, 0, 0}, {3, 0, 1.65}, true), 0)
}

@(test)
test_flash_blast_respects_the_world :: proc(t: ^testing.T) {
	wall := physics.Aabb {
		min = {2, -10, 0},
		max = {2.5, 10, 5},
	}
	gs := make_world(wall)
	defer destroy_world(&gs)

	// Looking at the flash, in the open.
	exposed := place(&gs, 0, {1, 0, 0})
	exposed.yaw = 180 // facing back toward the centre at x=0

	// Same distance the other side of the wall.
	place(&gs, 1, {4, 0, 0})

	result := flash_blast(&gs, {0, 0, 1.65})
	testing.expect_value(t, result.count, 1)
	testing.expect_value(t, result.items[0].pawn, 0)
	testing.expect(t, result.items[0].duration > 0)
}

@(test)
test_flash_opacity_holds_then_clears :: proc(t: ^testing.T) {
	total := f32(2)

	testing.expect_value(t, flash_opacity(total, total), 1) // just went off
	testing.expect_value(t, flash_opacity(0, total), 0) // over
	testing.expect_value(t, flash_opacity(-1, total), 0) // and stays over

	// Fully white through the hold, then monotonically clearing.
	held := total * (1 - FLASH_HOLD_FRACTION * 0.5)
	testing.expect_value(t, flash_opacity(held, total), 1)

	previous := f32(1)
	for step in 1 ..= 10 {
		remaining := total * (1 - f32(step) / 10)
		o := flash_opacity(remaining, total)
		testing.expectf(t, o <= previous, "opacity rose from {} to {}", previous, o)
		previous = o
	}
	testing.expect_value(t, previous, 0)
}

// ------------------------------------------------------------------ zones

@(test)
test_zone_blooms_and_fades :: proc(t: ^testing.T) {
	spec := ZONE_SPECS[.Smoke]

	testing.expect_value(t, zone_radius(.Smoke, -1), 0)
	testing.expect_value(t, zone_radius(.Smoke, spec.duration), 0)
	testing.expect_value(t, zone_radius(.Smoke, spec.duration + 5), 0)

	// Growing at the start.
	early := zone_radius(.Smoke, spec.bloom * 0.25)
	later := zone_radius(.Smoke, spec.bloom * 0.75)
	testing.expect(t, early > 0 && early < later, "must bloom rather than pop")

	// Full in the middle.
	testing.expect_value(t, zone_radius(.Smoke, spec.duration * 0.5), spec.radius)

	// Shrinking at the end.
	fading := zone_radius(.Smoke, spec.duration - spec.fade * 0.5)
	testing.expect(t, fading > 0 && fading < spec.radius, "must fade rather than vanish")
}

@(test)
test_fire_burns_while_you_stand_in_it :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	inside := place(&gs, 0, {0, 0, 0})
	place(&gs, 1, {20, 0, 0}) // well clear

	testing.expect(t, spawn_zone(&gs, .Fire, 5, .T, {0, 0, 0}))

	// Let it bloom, then collect a few seconds of burning.
	total := 0
	hit_ids: map[int]bool
	defer delete(hit_ids)
	for _ in 0 ..< int(3 * TICK_RATE) {
		ev := tick_zones(&gs, TICK_DT)
		for i in 0 ..< ev.count {
			total += ev.items[i].amount
			hit_ids[ev.items[i].pawn] = true
			testing.expect_value(t, ev.items[i].owner, 5)
		}
	}

	testing.expect(t, total > 0, "standing in fire must burn")
	testing.expect(t, hit_ids[0], "the pawn in the fire was never hit")
	testing.expect(t, !hit_ids[1], "a pawn 20 m away was burned")
	_ = inside
}

@(test)
test_zones_expire :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	testing.expect(t, spawn_zone(&gs, .Smoke, 0, .T, {0, 0, 0}))
	steps := int((ZONE_SPECS[.Smoke].duration + 1) * TICK_RATE)
	for _ in 0 ..< steps do tick_zones(&gs, TICK_DT)

	for &z in gs.zones {
		testing.expect(t, !z.active, "a zone outlived its duration")
	}
}

@(test)
test_zone_pool_is_bounded :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	for i in 0 ..< MAX_ZONES {
		testing.expectf(t, spawn_zone(&gs, .Smoke, 0, .T, {}), "pool refused slot {}", i)
	}
	testing.expect(t, !spawn_zone(&gs, .Smoke, 0, .T, {}), "the pool must report being full")
}
