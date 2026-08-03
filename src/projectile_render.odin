package main

import "core:math/linalg"
import "game"
import "protocol"

// Grenades in flight, drawn from the snapshot on the same delayed clock as the
// other players. Nothing here decides anything: the server owns where a
// grenade is and when it goes off, and this only shows the arc on its way.
//
// The meshes are the world_* variants of what the hands hold, so the thing that
// left your palm and the thing arcing toward you are literally the same model.

// The world variants of the viewmodels in hand_view.odin. Same models, origin
// at the grip rather than at the eye.
PROJECTILE_MODELS := [game.Grenade_Kind]string {
	.He      = "world_he",
	.Flash   = "world_flash",
	.Smoke   = "world_smoke",
	.Molotov = "world_molotov",
}

// Colours by kind, so a smoke is recognisable before it blooms -- reading what
// is coming at you is most of what utility is about. The models carry their own
// textures now; this stays because the HUD belt names the same four things and
// has to agree with what flies (hud_nades.odin).
PROJECTILE_COLORS := [game.Grenade_Kind][3]f32 {
	.He      = {0.22, 0.26, 0.20}, // olive
	.Flash   = {0.75, 0.72, 0.60}, // pale metal
	.Smoke   = {0.35, 0.42, 0.48}, // blue-grey
	.Molotov = {0.55, 0.30, 0.12}, // bottle brown
}

Projectile_Draw :: struct {
	kind:     game.Grenade_Kind,
	id:       u8, // the server's slot, which is what gives each one its own spin
	position: [3]f32,
}

Projectile_View :: struct {
	drawn:       [protocol.MAX_SNAPSHOT_PROJECTILES]Projectile_Draw,
	drawn_count: int,
}

projectiles: Projectile_View

// Fills the draw list from the two snapshots bracketing the render time, the
// same pair remote_view uses. Matching is by id -- the server's slot index --
// which is what makes an arc smooth rather than a series of jumps.
interpolate_projectiles :: proc(from, to: ^protocol.Snapshot, factor: f32) {
	projectiles.drawn_count = 0
	if from == nil do return

	for i in 0 ..< int(from.projectile_count) {
		p := from.projectiles[i]
		if int(p.kind) >= game.GRENADE_COUNT do continue

		position := p.position
		if to != nil {
			// Same id in the newer snapshot: interpolate. Missing means it
			// went off between the two, and it stays where it last was for
			// this frame rather than snapping to the detonation.
			for j in 0 ..< int(to.projectile_count) {
				if to.projectiles[j].id != p.id do continue
				position = linalg.lerp(p.position, to.projectiles[j].position, factor)
				break
			}
		}

		projectiles.drawn[projectiles.drawn_count] = {
			kind     = game.Grenade_Kind(p.kind),
			id       = p.id,
			position = position,
		}
		projectiles.drawn_count += 1
	}
}

// How fast a thrown grenade tumbles, degrees a second. Not simulated -- the
// snapshot carries no rotation, and nothing is decided by which way a grenade
// faces -- but a model frozen in mid-air reads as a bug, so the spin comes off
// the render clock with the slot index for a phase so two in the air never
// turn in lockstep.
PROJECTILE_SPIN :: f32(420)

submit_projectiles :: proc() {
	spin := f32(game.clock.tick_count) * game.TICK_DT * PROJECTILE_SPIN
	for i in 0 ..< projectiles.drawn_count {
		d := &projectiles.drawn[i]
		yaw := spin + f32(d.id) * 137 // any turn that is not a multiple of 360
		add_world_model(
			PROJECTILE_MODELS[d.kind],
			prop_transform_oriented(
				d.position,
				1,
				game.yaw_right(yaw),
				game.yaw_forward_flat(yaw),
				{0, 0, 1},
			),
		)
	}
}
