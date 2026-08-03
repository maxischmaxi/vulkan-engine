package main

import "game"
import "protocol"

// Smoke clouds and burning ground, off the snapshot. The radius comes over the
// wire rather than being re-derived from an age this side would have to track,
// so what is drawn is exactly what the server blocks sight with.
//
// Neither is geometry any more. The cloud is the volumetric shader
// (smoke_render.odin) with particles curling off its rim, the fire is particles
// and a light. Both used to be boxes standing in for the real thing, and the
// smoke's box outlived its usefulness badly: it was opaque and wrote depth, so
// the ray march stopped dead in the middle of the very cloud it was standing in
// for and the far half was never accumulated.

// The fire's light, which is most of what sells it from a distance.
FIRE_LIGHT_COLOR :: [3]f32{1.0, 0.55, 0.18}
FIRE_LIGHT_INTENSITY :: f32(14)

Zone_Draw :: struct {
	kind:     game.Zone_Kind,
	id:       u8, // the server's slot; each zone carries its own emitter remainder
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
			id       = z.id,
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
			// The cloud itself is smoke_render.odin's ray march, built from
			// this same list. All that happens here is the rim: puffs curling
			// off the sphere, which is what stops it reading as a sphere.
			fx_smoke_cloud(
				z.id,
				z.position + {0, 0, z.radius * 0.6},
				z.radius,
				game.ZONE_SPECS[.Smoke].radius,
				ui.dt,
			)
		case .Fire:
			fx_fire_zone(z.id, z.position, z.radius, ui.dt)
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
