package game

import "../physics"
import "core:math/linalg"
import "core:testing"

// The practice range as numbers: it must sit outside the playfield, every
// band and the booth must be standable, and the booth window must actually
// let a shot out. Geometry written as numbers fails as numbers.

@(private = "file")
baked_dust2 :: proc() -> (brushes: []Brush, grid: physics.Grid, collision: []physics.Aabb) {
	brushes = build_dust2()
	collision = bake_collision(brushes)
	grid = physics.grid_build(collision)
	return
}

@(private = "file")
destroy_baked :: proc(brushes: []Brush, grid: ^physics.Grid, collision: []physics.Aabb) {
	physics.grid_destroy(grid)
	delete(collision)
	delete(brushes)
}

@(test)
test_practice_range_outside_playfield :: proc(t: ^testing.T) {
	// The dust2 shell ends at 52; live respawns and bench bots must never see
	// the range, and the range must never poke into the map.
	for area in PRACTICE_BOT_AREAS {
		testing.expect(t, area.min.x > 52)
		testing.expect(t, area.min.x >= PRACTICE_BOUNDS.max.x)
		testing.expect(t, area.max.x < 110)
		testing.expect(t, area.min.y > -20 && area.max.y < 20)
	}
	testing.expect(t, PRACTICE_BOUNDS.min.x > 52)
	testing.expect(t, practice_inside_bounds(PRACTICE_PLAYER_SPAWN))

	// The spawn list feeds live respawns; the range must not be on it.
	for area in MAP_SPAWN_AREAS {
		testing.expect(t, area.max.x <= 52)
	}
}

@(test)
test_practice_range_walkable :: proc(t: ^testing.T) {
	brushes, grid, collision := baked_dust2()
	defer destroy_baked(brushes, &grid, collision)

	// The player probe is larger than the bot hull, so a band its centre fits
	// in fits the targets too.
	probe := physics.Body {
		radius = PLAYER_RADIUS,
		height = PLAYER_HEIGHT,
	}

	for area in PRACTICE_BOT_AREAS {
		center := [2]f32{(area.min.x + area.max.x) * 0.5, (area.min.y + area.max.y) * 0.5}
		z, found := physics.grid_ground_below(&grid, {center.x, center.y, area.floor + 2}, 5)
		testing.expect(t, found)
		testing.expect(
			t,
			!physics.grid_overlaps_any(&grid, physics.body_aabb_at(probe, {center.x, center.y, z + 0.01})),
		)
	}

	z, found := physics.grid_ground_below(&grid, PRACTICE_PLAYER_SPAWN + {0, 0, 1}, 3)
	testing.expect(t, found)
	testing.expect(t, z <= PRACTICE_PLAYER_SPAWN.z)
	testing.expect(
		t,
		!physics.grid_overlaps_any(&grid, physics.body_aabb_at(probe, PRACTICE_PLAYER_SPAWN)),
	)
}

@(test)
test_practice_booth_sightline :: proc(t: ^testing.T) {
	brushes, grid, collision := baked_dust2()
	defer destroy_baked(brushes, &grid, collision)

	eye := PRACTICE_PLAYER_SPAWN + {0, 0, EYE_HEIGHT}

	// Straight down-range: the window between counter and open sky must reach
	// past the far band to its wall.
	if hit, ok := physics.grid_raycast(&grid, eye, {1, 0, 0}, 40); ok {
		testing.expect(t, hit.t > PRACTICE_BOT_AREAS[2].max.x - eye.x)
	}

	// The shin of a target at the near band's close edge: the counter must
	// not eat shots at the shortest distance the range offers.
	targets := [][3]f32 {
		{PRACTICE_BOT_AREAS[0].min.x, 0, 0.3}, // near, low
		{PRACTICE_BOT_AREAS[1].min.x, 12, 0.9}, // mid, torso, off-axis
		{PRACTICE_BOT_AREAS[2].max.x, -12, 1.0}, // far corner
	}
	for target in targets {
		delta := target - eye
		dist := linalg.length(delta)
		hit, ok := physics.grid_raycast(&grid, eye, delta / dist, dist)
		if ok {
			testing.expectf(t, hit.t >= dist - 0.35, "shot to {} blocked at t={}", target, hit.t)
		}
	}
}
