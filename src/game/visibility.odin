package game

import "../physics"
import "core:math/linalg"

// Who can see whom. The server filters each client's snapshot through this so
// a pawn nobody can see is a pawn nobody is told about -- which is the only
// structural answer to a wallhack, because a client that never receives the
// position cannot draw it.
//
// It lives in the game package rather than the server for two reasons: the
// tests here run without a wire, and the smoke grenade's sight blocking hangs
// off sight_blocked below, where server and client necessarily read the same
// rule off the same data.

// A sanity limit rather than an optimisation -- the map's diagonal is well
// under it, so it only ever catches a nonsense argument. Culling sight at a
// game-relevant distance would hide players across long, which is a sight line
// the map is built around.
VISION_MAX_RANGE :: f32(200)

// A sight line that ends exactly on a surface must not count as hitting it:
// the foot sample sits a finger's width off the floor, and a ray aimed at it
// from far enough away grazes the floor plane it is standing on.
VISION_SURFACE_BIAS :: f32(0.02)

// Heights on the target hull the sight lines are aimed at, as fractions of its
// height. Ordered by how often each one is the first to be visible: the chest
// wins whenever a target is in the open, and the two flank samples are what
// catch a shoulder leaning out of cover before anything else does.
VISION_SAMPLE_CHEST :: f32(0.55)
VISION_SAMPLE_HEAD :: f32(0.90)
VISION_SAMPLE_FEET :: f32(0.10)

// How far out along the hull the flank samples sit. Not the full radius: a
// point exactly on the hull's corner is as likely to be inside the wall the
// target is hugging as outside it.
VISION_FLANK :: f32(0.8)

MAX_VISION_SAMPLES :: 5

// The points on `target` worth aiming a sight line at, given where the viewer
// stands. Returned in the order they should be tested.
//
// A single eye-to-eye ray is not enough and the failure is not subtle: a player
// whose head is behind a crate but whose whole body is in the open would be
// invisible, and one peeking a corner would stay hidden until fully committed.
vision_samples :: proc(target: Pawn, from: [3]f32) -> (points: [MAX_VISION_SAMPLES][3]f32, count: int) {
	base := target.body.position
	height := target.body.height

	points[0] = base + {0, 0, height * VISION_SAMPLE_CHEST}
	points[1] = base + {0, 0, height * VISION_SAMPLE_HEAD}
	count = 2

	// Sideways relative to the viewer, so the two flank points always straddle
	// the silhouette rather than lying along it. Degenerate when the viewer is
	// directly above or below, and there the chest and head samples already
	// describe the hull.
	delta := base - from
	horizontal := [3]f32{delta.x, delta.y, 0}
	if linalg.dot(horizontal, horizontal) > 1e-6 {
		side := linalg.normalize([3]f32{-horizontal.y, horizontal.x, 0})
		offset := side * target.body.radius * VISION_FLANK
		chest := base + {0, 0, height * VISION_SAMPLE_CHEST}
		points[count] = chest + offset
		points[count + 1] = chest - offset
		count += 2
	}

	points[count] = base + {0, 0, height * VISION_SAMPLE_FEET}
	count += 1
	return
}

// Whether anything stands between two points -- the world, or a smoke cloud.
//
// Both ends of the wire call this, which is the whole reason the smoke test
// lives here rather than beside the renderer: a cloud that blocked the
// snapshot but not the client's own reasoning (or the other way round) would
// be a smoke you can see through and shoot into, or one that hides an enemy
// the server still sends.
sight_blocked :: proc(gs: ^Game_State, from, to: [3]f32) -> bool {
	delta := to - from
	distance := linalg.length(delta)
	if distance < 0.001 do return false
	if distance > VISION_MAX_RANGE do return true

	// Shortened rather than dropped: the bias belongs on the far end, where a
	// sample sits against a surface, not on the eye.
	reach := max(distance - VISION_SURFACE_BIAS, 0.001)
	if _, hit := physics.grid_raycast(&gs.grid, from, delta / distance, reach); hit {
		return true
	}

	// Smoke second: it is the cheaper test but the rarer hit, and a wall
	// already ended most sight lines above.
	for &z in gs.zones {
		if zone_blocks_sight(z, from, to) do return true
	}
	return false
}

// Whether a pawn at `eye` can see `target`. Pawns deliberately do not block
// each other: a teammate standing in the doorway is not cover, and treating
// them as such would make visibility depend on who else is alive.
pawn_visible :: proc(gs: ^Game_State, eye: [3]f32, target: Pawn) -> bool {
	if !target.active do return false

	points, count := vision_samples(target, eye)
	for i in 0 ..< count {
		if !sight_blocked(gs, eye, points[i]) do return true
	}
	return false
}

// The same question between two pawns, which is what the snapshot filter asks.
// Blind while dead: a corpse has no eyes, and the viewer's own rules for what
// a dead client may still see belong on the server, not here.
pawn_can_see :: proc(gs: ^Game_State, viewer, target: ^Pawn) -> bool {
	if !viewer.active || !viewer.alive do return false
	return pawn_visible(gs, eye_position(viewer^), target^)
}
