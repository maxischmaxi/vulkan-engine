package main

import "core:log"
import "core:slice"
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
// Debug builds only. The spawn checks read world_collision, so they have to run
// after bake_world; the face check takes the clipper's output directly.

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

// The clipper's contract, checked rather than trusted: no two visible faces may
// be coplanar, same-facing and overlapping with any real area. That is exactly
// the configuration a depth buffer cannot resolve -- both surfaces are equally
// near, so which one wins comes down to rasterisation rounding, and it comes out
// differently from one pixel and one frame to the next. A map satisfying this
// cannot flicker no matter what its author builds.
//
// Note what is *not* checked: brushes may interpenetrate as freely as ever. That
// is the whole point of authoring with boxes, and resolving it is the clipper's
// job rather than the author's.
//
// This panics where the spawn checks only log. A failure here is a bug in
// map_clip, not a mistake in the map, and a guarantee that lets the build
// continue is not a guarantee.
verify_face_partition :: proc(faces: []Baked_Face) {
	when !ODIN_DEBUG do return

	sorted := make([]Baked_Face, len(faces), context.temp_allocator)
	copy(sorted, faces)
	slice.sort_by(sorted, plane_less)

	found := 0
	for i in 0 ..< len(sorted) {
		for j in i + 1 ..< len(sorted) {
			// Sorted, so once either differs no later face can match this one
			// either. Anchoring the coordinate on i rather than on j-1 is what
			// makes every pair within PLANE_EPS get compared.
			if sorted[j].face != sorted[i].face do break
			if sorted[j].coord - sorted[i].coord > PLANE_EPS do break

			area := face_overlap_area(sorted[i], sorted[j])
			if area <= 0 do continue

			found += 1
			if found <= 10 {
				log.errorf(
					"Map: z-fight -- brush {} ({}) and brush {} ({}) both claim {:.2f} m2 of {} at {:.3f}",
					sorted[i].brush,
					Material_ID(sorted[i].material),
					sorted[j].brush,
					Material_ID(sorted[j].material),
					area,
					sorted[i].face,
					sorted[i].coord,
				)
			}
		}
	}

	if found > 0 {
		log.panicf("Map: {} pairs of visible faces overlap -- the clipper is broken", found)
	}
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
