package main

import "../game"
import "../protocol"

// What happened at a place this tick, and who is near enough to be told. This
// exists because of fog of war: the client used to derive remote footsteps and
// gunfire from the positions in the snapshot, so a pawn filtered out of the
// snapshot would also have gone silent. Hearing an enemy you cannot see is half
// of a tactical shooter, so the server says what happened and the filter for it
// is distance, never sight.
//
// Detonations come through the same door. They are the same shape of fact --
// one tick, one position -- and the client needs them for the effect as much as
// for the noise; without them an explosion is a projectile silently going
// missing from the snapshot, which one dropped datagram imitates perfectly.
//
// Events last exactly one tick. A lost datagram costs one footstep, which is
// why they never enter the delta machinery.

Pending_Event :: struct {
	kind:     protocol.Event_Kind,
	weapon:   u8,
	source:   int, // the pawn that made it; it hears its own sounds locally
	position: [3]f32,
	range:    f32,
}

// Room for a full server having a loud tick. The snapshot block is smaller
// still (protocol.MAX_WORLD_EVENTS); this one only has to hold what happened
// before it is split per listener.
MAX_PENDING_EVENTS :: 32

pending_events: [MAX_PENDING_EVENTS]Pending_Event
pending_event_count: int

// The cadence accumulator per pawn, indexed by pawn id. Server-side only: the
// owning client runs the same procedure over its own predicted movement, so
// its own steps never wait for a round trip.
footstep_travelled: [game.MAX_PAWNS]f32

event_reset :: proc() {
	pending_event_count = 0
}

// `source` is the pawn responsible, or -1 for nobody. A detonation has to pass
// -1: the throw belongs to a pawn, but the bang belongs to the world, and
// crediting it to the thrower is exactly what would leave the one player who
// most needs to see it looking at nothing.
queue_event :: proc(
	kind: protocol.Event_Kind,
	source: int,
	position: [3]f32,
	range: f32,
	weapon: u8 = 0,
) {
	if pending_event_count >= MAX_PENDING_EVENTS do return
	pending_events[pending_event_count] = {
		kind     = kind,
		weapon   = weapon,
		source   = source,
		position = position,
		range    = range,
	}
	pending_event_count += 1
}

// Runs after everything has moved -- bots included, which is why it walks the
// pawn array rather than the client slots.
tick_world_events :: proc(dt: f32) {
	for &p, id in sv.gs.pawns {
		if !p.active {
			footstep_travelled[id] = 0
			continue
		}

		// Measured off the ground actually covered this tick, not off the
		// velocity vector: bots are displaced directly by grid_step_move and
		// keep a zero horizontal velocity, so reading the vector would make
		// every one of them silent. Both pawn kinds set prev_position at the
		// top of their own tick, before anything moves them.
		stepped: bool
		footstep_travelled[id], stepped = game.footstep_step(
			footstep_travelled[id],
			game.footstep_speed(p.prev_position, p.body.position, dt),
			p.body.on_ground,
			p.alive,
			dt,
			game.footstep_min_speed(p.is_bot),
		)
		if stepped {
			queue_event(.Footstep, id, p.body.position, game.FOOTSTEP_HEARING_RANGE)
		}

		if fired_this_tick[id] {
			queue_event(
				.Gunshot,
				id,
				game.eye_position(p),
				game.GUNSHOT_HEARING_RANGE,
				u8(gunshot_weapon(&p)),
			)
		}
	}
}

// Bot pawns keep weapon index 0 (the knife) while their hitscan stub fires, so
// a bot's gunshot would otherwise pick the knife's swing off the bank. The
// client's tracer path compensates the same way for the same reason -- see
// scan_remote_fire in remote.odin.
@(private = "file")
gunshot_weapon :: proc(p: ^game.Pawn) -> int {
	if p.is_bot && game.WEAPONS[p.weapon.index].melee do return game.WEAPON_AK
	return p.weapon.index
}

// The listener's share of this tick's events. Distance only: a wall muffles
// nothing here, which is deliberate -- this is the information fog of war is
// meant to let through.
fill_client_events :: proc(s: ^protocol.Snapshot, listener: [3]f32, own_pawn: int) {
	s.event_count = 0
	for i in 0 ..< pending_event_count {
		e := &pending_events[i]
		// You hear your own feet and your own gun locally, without the wire.
		if e.source == own_pawn do continue
		if !game.sound_audible(listener, e.position, e.range) do continue
		protocol.snapshot_add_event(s, {kind = e.kind, weapon = e.weapon, position = e.position})
	}
}
