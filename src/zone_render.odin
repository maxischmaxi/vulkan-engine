package main

import "game"
import "protocol"

// Smoke clouds and burning ground, off the snapshot. The radius comes over the
// wire rather than being re-derived from an age this side would have to track,
// so what is drawn is exactly what the server blocks sight with.
//
// Boxes and a light for now. The volumetric smoke is its own piece of work
// (its own render pass, a depth buffer it can sample, and a split of
// record_scene_pass to get there); none of the netcode or the sight blocking
// depends on it, which is why it comes last rather than first.

SMOKE_COLOR :: [3]f32{0.62, 0.64, 0.66}
FIRE_COLOR :: [3]f32{0.95, 0.45, 0.12}

// The fire's light, which is most of what sells it from a distance.
FIRE_LIGHT_COLOR :: [3]f32{1.0, 0.55, 0.18}
FIRE_LIGHT_INTENSITY :: f32(14)

Zone_Draw :: struct {
	kind:     game.Zone_Kind,
	position: [3]f32,
	radius:   f32,
}

Zone_View :: struct {
	drawn:       [protocol.MAX_SNAPSHOT_ZONES]Zone_Draw,
	drawn_count: int,
}

zones: Zone_View

// Zones change slowly and are sent in full, so the newest snapshot is taken as
// it stands rather than interpolated between two.
read_snapshot_zones :: proc(s: ^protocol.Snapshot) {
	zones.drawn_count = 0
	if s == nil do return

	for i in 0 ..< int(s.zone_count) {
		z := s.zones[i]
		if int(z.kind) > len(game.Zone_Kind) - 1 do continue
		if z.radius <= 0 do continue

		zones.drawn[zones.drawn_count] = {
			kind     = game.Zone_Kind(z.kind),
			position = z.position,
			radius   = z.radius,
		}
		zones.drawn_count += 1
	}
}

submit_zones :: proc() {
	for i in 0 ..< zones.drawn_count {
		z := &zones.drawn[i]
		switch z.kind {
		case .Smoke:
			// A cube standing in for the cloud: the right size in the right
			// place, so lines of sight read correctly even before it looks
			// like smoke.
			add_world_prop(
				prop_transform(z.position + {0, 0, z.radius * 0.5}, {z.radius, z.radius, z.radius}),
				SMOKE_COLOR,
				roughness = 1,
			)
		case .Fire:
			// Flat and wide: fire is a patch of ground, not a ball.
			add_world_prop(
				prop_transform(z.position + {0, 0, 0.15}, {z.radius, z.radius, 0.3}),
				FIRE_COLOR,
				roughness = 0.9,
				emissive = 1,
			)
			// Re-added every frame with a one-frame life, so it follows the
			// zone rather than needing its own bookkeeping.
			add_transient_light(
				z.position + {0, 0, 0.6},
				FIRE_LIGHT_COLOR,
				FIRE_LIGHT_INTENSITY,
				z.radius * 3,
				ui.dt,
			)
		}
	}
}
