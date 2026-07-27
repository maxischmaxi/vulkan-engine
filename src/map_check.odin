package main

import "core:log"
import "physics"

// What a map has to satisfy before anything is allowed to stand in it.
//
// The check exists because of the two ways this map was wrong on the way here,
// both of them invisible from anywhere a screenshot could be taken from: a rock
// mass meant to fill the pocket beside the upper tunnel was written with the
// tunnel's own coordinates and sealed it end to end, and long ran to a dead end
// because the floor tying it into the site was never laid. Geometry written as
// numbers fails as numbers, so it is worth testing as numbers.
//
// Debug builds only. It reads world_collision, so it has to run after bake_world.

// The clearance a stance needs to be considered free, and how far under a point
// the floor may be before it counts as a hole rather than a step down.
CHECK_DROP :: f32(1.0)

// Every room on the spawn list must have a floor under its centre and room for a
// standing player over it. A room that fails is either filled in or floating.
verify_spawn_areas :: proc() {
	when !ODIN_DEBUG do return

	probe := physics.Body {
		radius = PLAYER_RADIUS,
		height = PLAYER_HEIGHT,
	}
	failed := 0

	for area, i in MAP_SPAWN_AREAS {
		center := [2]f32{(area.min.x + area.max.x) * 0.5, (area.min.y + area.max.y) * 0.5}

		z, found := physics.ground_below(
			{center.x, center.y, area.floor + BOT_PROBE_UP},
			world_collision,
			BOT_PROBE_UP + CHECK_DROP,
		)
		if !found {
			log.errorf("Map: room {} at {} has no floor under it", i, center)
			failed += 1
			continue
		}

		if physics.overlaps_any(
			physics.body_aabb_at(probe, {center.x, center.y, z + 0.01}),
			world_collision,
		) {
			log.errorf("Map: room {} at {} is filled in -- nothing fits there", i, center)
			failed += 1
		}
	}

	if failed > 0 {
		log.errorf("Map: {} of {} rooms unusable", failed, len(MAP_SPAWN_AREAS))
		return
	}
	log.infof("Map: {} rooms verified", len(MAP_SPAWN_AREAS))
}

// The player's own spawn, which no room list covers.
verify_player_spawn :: proc() {
	when !ODIN_DEBUG do return

	probe := physics.Body {
		position = SPAWN_POSITION,
		radius   = PLAYER_RADIUS,
		height   = PLAYER_HEIGHT,
	}
	if physics.overlaps_any(physics.body_aabb(probe), world_collision) {
		log.errorf("Map: the player spawn at {} is inside geometry", SPAWN_POSITION)
	}
}
