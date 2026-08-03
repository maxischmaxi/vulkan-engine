package main

import "../game"
import "../physics"
import "core:log"

// The server's half of grenades: turning a throw into a projectile, and a
// detonation into whatever it does to the world. The flight itself is
// game/projectile.odin, which knows nothing about pawns or clients.

// One grenade leaves a pawn's hand. Everything about whether they were allowed
// to is the caller's business; this is the mechanics of the throw.
throw_grenade :: proc(pawn_id: int, kind: game.Grenade_Kind, mode: game.Throw_Mode) -> bool {
	p := &sv.gs.pawns[pawn_id]
	if !p.active || !p.alive do return false

	velocity := game.throw_velocity(p.yaw, p.pitch, mode, p.body.velocity)
	origin := game.throw_origin(p^)
	if !game.spawn_projectile(&sv.gs, kind, pawn_id, p.team, origin, velocity) {
		log.warnf("Server: projectile pool full, {} throw dropped", game.GRENADES[kind].name)
		return false
	}

	log.infof(
		"Server: pawn {} threw {} ({}) from {}",
		pawn_id,
		game.GRENADES[kind].name,
		mode,
		origin,
	)
	return true
}

// A projectile reached the end of its life. What each kind does lives here
// because it needs the pawn list; the decision that it *should* go off was
// made in the game package, off nothing but the projectile's own state.
apply_detonation :: proc(d: game.Detonation) {
	log.infof("Server: {} detonated at {}", game.GRENADES[d.kind].name, d.position)

	switch d.kind {
	case .He:
		blast := game.he_blast(&sv.gs, d.position)
		for i in 0 ..< blast.count {
			hit := blast.items[i]
			queue_damage(d.position, hit.pawn, hit.amount)
			if game.damage_pawn(&sv.gs.pawns[hit.pawn], hit.amount, hit.armor_pen) {
				// Credited to the thrower, including when that is the victim:
				// blowing yourself up is a death like any other.
				on_pawn_killed(d.owner, hit.pawn)
			}
		}
		if blast.count > 0 {
			log.infof("Server: he caught {} pawn(s)", blast.count)
		}

	case .Flash:
		result := game.flash_blast(&sv.gs, d.position)
		for i in 0 ..< result.count {
			hit := result.items[i]
			p := &sv.gs.pawns[hit.pawn]
			// The longer blind wins: a second flash while still blind extends
			// it, but a weaker one cannot cut a stronger one short.
			if hit.duration > p.flash_left {
				p.flash_left = hit.duration
				p.flash_total = hit.duration
			}
		}
		if result.count > 0 {
			log.infof("Server: flash blinded {} pawn(s)", result.count)
		}

	case .Smoke:
		spawn_effect_zone(.Smoke, d)

	case .Molotov:
		spawn_effect_zone(game.MOLOTOV_ZONE, d)
	}
}

@(private = "file")
spawn_effect_zone :: proc(kind: game.Zone_Kind, d: game.Detonation) {
	// Dropped onto the ground under the detonation: a smoke that goes off a
	// metre up should still bloom from the floor, or it would hang with a gap
	// under it that players could see through.
	position := d.position
	if z, found := physics.grid_ground_below(&sv.gs.grid, d.position + {0, 0, 0.5}, 4); found {
		position.z = z
	}

	if !game.spawn_zone(&sv.gs, kind, d.owner, d.team, position) {
		log.warnf("Server: zone pool full, {} had no effect", kind)
	}
}

// Fire burning whoever stands in it. Separate from detonations because it
// happens every tick for as long as the zone lives.
tick_effect_zones :: proc(dt: f32) {
	burns := game.tick_zones(&sv.gs, dt)
	for i in 0 ..< burns.count {
		hit := burns.items[i]
		p := &sv.gs.pawns[hit.pawn]
		queue_damage(p.body.position + {0, 0, -1}, hit.pawn, hit.amount)
		if game.damage_pawn(p, hit.amount) {
			on_pawn_killed(hit.owner, hit.pawn)
		}
	}
}
