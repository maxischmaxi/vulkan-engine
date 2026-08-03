package game

import "../physics"
import "core:math"
import "core:testing"

// The sight tests the snapshot filter is built on. A false positive here is a
// wallhack the server hands out itself; a false negative is a player who
// vanishes in the open, which is worse to play against than no fog of war at
// all. Both directions are pinned below.

// A floor, plus whatever walls the caller adds. Ground sits at z = 0 like the
// real map's (see GROUND_Z in map_build.odin).
@(private = "file")
make_world :: proc(walls: ..physics.Aabb) -> (gs: Game_State) {
	boxes := make([]physics.Aabb, 1 + len(walls))
	boxes[0] = {
		min = {-50, -50, -1},
		max = {50, 50, 0},
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

// A wall spanning y, standing at x, tall enough to hide a standing player.
@(private = "file")
wall_at_x :: proc(x: f32) -> physics.Aabb {
	return {min = {x - 0.3, -10, 0}, max = {x + 0.3, 10, 5}}
}

@(private = "file")
place :: proc(gs: ^Game_State, id: int, position: [3]f32) -> ^Pawn {
	p := &gs.pawns[id]
	init_pawn(p, position, 0)
	return p
}

@(test)
test_open_ground_is_visible :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	viewer := place(&gs, 0, {0, 0, 0})
	target := place(&gs, 1, {10, 0, 0})

	testing.expect(t, pawn_can_see(&gs, viewer, target), "nothing is in the way")
	testing.expect(t, pawn_can_see(&gs, target, viewer), "and sight is symmetric here")
}

@(test)
test_wall_blocks_sight :: proc(t: ^testing.T) {
	gs := make_world(wall_at_x(5))
	defer destroy_world(&gs)

	viewer := place(&gs, 0, {0, 0, 0})
	target := place(&gs, 1, {10, 0, 0})

	testing.expect(t, !pawn_can_see(&gs, viewer, target), "the wall is between them")
	testing.expect(t, !pawn_can_see(&gs, target, viewer))
}

// The reason there are five samples instead of one. The wall hides the head
// but not the body, and a single eye-to-eye ray would call this invisible.
@(test)
test_partial_cover_stays_visible :: proc(t: ^testing.T) {
	// A low wall: 1.2 m, so it covers the feet but leaves chest and head clear
	// of a viewer standing at the same height.
	low := physics.Aabb {
		min = {5, -10, 0},
		max = {5.6, 10, 1.2},
	}
	gs := make_world(low)
	defer destroy_world(&gs)

	viewer := place(&gs, 0, {0, 0, 0})
	target := place(&gs, 1, {10, 0, 0})

	testing.expect(t, pawn_can_see(&gs, viewer, target), "the upper body clears the low wall")
}

// The flank samples, and the whole reason they exist: a pillar narrower than
// the player covers the centre line -- head, chest and feet all sit on it --
// while both shoulders stay in the open. Every centred sample is blocked here,
// so this passes only because the hull is sampled sideways too.
@(test)
test_pillar_narrower_than_the_player :: proc(t: ^testing.T) {
	// 30 cm wide, against flank samples that sit 24 cm off the centre line
	// (PLAYER_RADIUS * VISION_FLANK). Standing close to the target, because a
	// sight line only reaches its full sideways offset at the far end -- the
	// same pillar halfway down the sight line would still cover the shoulders.
	pillar := physics.Aabb {
		min = {9.0, -0.15, 0},
		max = {9.3, 0.15, 5},
	}
	gs := make_world(pillar)
	defer destroy_world(&gs)

	viewer := place(&gs, 0, {0, 0, 0})
	target := place(&gs, 1, {10, 0, 0})

	eye := eye_position(viewer^)
	points, count := vision_samples(target^, eye)
	testing.expect_value(t, count, MAX_VISION_SAMPLES)

	// Centre line first: chest, head and feet are all behind the pillar.
	testing.expect(t, sight_blocked(&gs, eye, points[0]), "chest is on the centre line")
	testing.expect(t, sight_blocked(&gs, eye, points[1]), "so is the head")
	testing.expect(t, sight_blocked(&gs, eye, points[4]), "and so are the feet")

	// The shoulders are not.
	testing.expect(t, !sight_blocked(&gs, eye, points[2]), "left shoulder clears the pillar")
	testing.expect(t, !sight_blocked(&gs, eye, points[3]), "right shoulder clears it too")

	testing.expect(t, pawn_can_see(&gs, viewer, target), "one clear sample is enough")
}

@(test)
test_samples_straddle_the_hull :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	target := place(&gs, 1, {10, 0, 0})
	points, count := vision_samples(target^, {0, 0, EYE_HEIGHT})
	testing.expect_value(t, count, MAX_VISION_SAMPLES)

	// Every sample sits inside the hull's height, and the flank pair lands on
	// opposite sides of its centre line.
	for i in 0 ..< count {
		dz := points[i].z - target.body.position.z
		testing.expectf(t, dz > 0 && dz < target.body.height, "sample {} left the hull: dz {}", i, dz)
	}
	testing.expect(t, points[2].y > target.body.position.y)
	testing.expect(t, points[3].y < target.body.position.y)

	// Viewer directly overhead: no horizontal direction to straddle, so the
	// flank pair drops out rather than producing a degenerate normal.
	_, overhead := vision_samples(target^, target.body.position + {0, 0, 10})
	testing.expect_value(t, overhead, 3)
}

@(test)
test_dead_and_inactive_pawns :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	viewer := place(&gs, 0, {0, 0, 0})
	target := place(&gs, 1, {10, 0, 0})

	// An inactive target is nobody's business.
	target.active = false
	testing.expect(t, !pawn_can_see(&gs, viewer, target))
	target.active = true

	// A dead viewer sees nothing; what a dead client is still shown is the
	// server's decision, not this function's.
	viewer.alive = false
	testing.expect(t, !pawn_can_see(&gs, viewer, target))
}

// The smoke grenade's whole point, and the reason the test lives beside fog of
// war rather than beside the renderer: one rule, both ends of the wire.
@(test)
test_smoke_blocks_sight :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	viewer := place(&gs, 0, {0, 0, 0})
	target := place(&gs, 1, {10, 0, 0})
	testing.expect(t, pawn_can_see(&gs, viewer, target), "clear before the smoke")

	// Halfway between them, at eye height.
	testing.expect(t, spawn_zone(&gs, .Smoke, 0, .T, {5, 0, 1.2}))

	// It blooms rather than popping, so sight survives the first instant.
	testing.expect(t, pawn_can_see(&gs, viewer, target), "a smoke must not block the tick it lands")

	for _ in 0 ..< int(ZONE_SPECS[.Smoke].bloom * TICK_RATE) + 4 do tick_zones(&gs, TICK_DT)
	testing.expect(t, !pawn_can_see(&gs, viewer, target), "a grown smoke must block")

	// And it clears again.
	for _ in 0 ..< int(ZONE_SPECS[.Smoke].duration * TICK_RATE) do tick_zones(&gs, TICK_DT)
	testing.expect(t, pawn_can_see(&gs, viewer, target), "sight must come back when it fades")
}

// Clipping the very edge of a cloud is not cover. Without a chord test a smoke
// would block every sight line that grazed its outermost centimetre.
@(test)
test_smoke_edge_does_not_block :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	radius := ZONE_SPECS[.Smoke].radius

	// The offset at which the chord is exactly the threshold, derived rather
	// than guessed: a line this far off centre cuts SMOKE_BLOCK_CHORD metres
	// of cloud, so anything further out must pass and anything nearer block.
	half := SMOKE_BLOCK_CHORD * 0.5
	edge := math.sqrt(radius * radius - half * half)

	// Just outside that: a graze.
	testing.expect(t, spawn_zone(&gs, .Smoke, 0, .T, {5, edge + 0.05, 1.2}))
	for _ in 0 ..< int(ZONE_SPECS[.Smoke].duration * 0.5 * TICK_RATE) do tick_zones(&gs, TICK_DT)

	eye := [3]f32{0, 0, 1.2}
	far := [3]f32{10, 0, 1.2}
	testing.expect(t, !sight_blocked(&gs, eye, far), "a graze must not count as cover")

	// The same cloud, aimed through its middle.
	middle := [3]f32{10, (edge + 0.05) * 2, 1.2}
	testing.expect(t, sight_blocked(&gs, eye, middle), "through the middle must block")
}

// Fire is not cover: it burns, it does not hide.
@(test)
test_fire_does_not_block_sight :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	testing.expect(t, spawn_zone(&gs, .Fire, 0, .T, {5, 0, 0}))
	for _ in 0 ..< int(ZONE_SPECS[.Fire].bloom * TICK_RATE) + 4 do tick_zones(&gs, TICK_DT)

	testing.expect(t, !sight_blocked(&gs, {0, 0, 0.5}, {10, 0, 0.5}))
}

@(test)
test_sight_range_limit :: proc(t: ^testing.T) {
	gs := make_world()
	defer destroy_world(&gs)

	testing.expect(t, !sight_blocked(&gs, {0, 0, 1}, {50, 0, 1}), "well inside the limit")
	testing.expect(
		t,
		sight_blocked(&gs, {0, 0, 1}, {VISION_MAX_RANGE + 10, 0, 1}),
		"past the sanity limit nothing is visible",
	)
	// Zero-length is not a sight line at all, and must not divide by it.
	testing.expect(t, !sight_blocked(&gs, {1, 2, 3}, {1, 2, 3}))
}
