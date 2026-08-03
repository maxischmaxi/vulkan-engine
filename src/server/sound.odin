package main

import "../game"
import "../protocol"

// What the world made a noise about this tick, and who is close enough to hear
// it. This exists because of fog of war: the client used to derive remote
// footsteps and gunfire from the positions in the snapshot, so a pawn filtered
// out of the snapshot would also have gone silent. Hearing an enemy you cannot
// see is half of a tactical shooter, so the server says what is heard and the
// filter for it is earshot, never sight.
//
// Events last exactly one tick. A lost datagram costs one footstep, which is
// why they never enter the delta machinery.

Pending_Sound :: struct {
	kind:     protocol.Sound_Kind,
	weapon:   u8,
	source:   int, // the pawn that made it; it hears its own sounds locally
	position: [3]f32,
	range:    f32,
}

// Room for a full server having a loud tick. The snapshot block is smaller
// still (protocol.MAX_SOUND_EVENTS); this one only has to hold what happened
// before it is split per listener.
MAX_PENDING_SOUNDS :: 32

pending_sounds: [MAX_PENDING_SOUNDS]Pending_Sound
pending_sound_count: int

// The cadence accumulator per pawn, indexed by pawn id. Server-side only: the
// owning client runs the same procedure over its own predicted movement, so
// its own steps never wait for a round trip.
footstep_travelled: [game.MAX_PAWNS]f32

sound_reset :: proc() {
	pending_sound_count = 0
}

queue_sound :: proc(kind: protocol.Sound_Kind, source: int, position: [3]f32, range: f32, weapon: u8 = 0) {
	if pending_sound_count >= MAX_PENDING_SOUNDS do return
	pending_sounds[pending_sound_count] = {
		kind     = kind,
		weapon   = weapon,
		source   = source,
		position = position,
		range    = range,
	}
	pending_sound_count += 1
}

// Runs after everything has moved -- bots included, which is why it walks the
// pawn array rather than the client slots.
tick_sounds :: proc(dt: f32) {
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
			queue_sound(.Footstep, id, p.body.position, game.FOOTSTEP_HEARING_RANGE)
		}

		if fired_this_tick[id] {
			queue_sound(
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

// The listener's share of this tick's noise. Distance only: a wall muffles
// nothing here, which is deliberate -- this is the information fog of war is
// meant to let through.
fill_client_sounds :: proc(s: ^protocol.Snapshot, listener: [3]f32, own_pawn: int) {
	s.sound_count = 0
	for i in 0 ..< pending_sound_count {
		e := &pending_sounds[i]
		// You hear your own feet and your own gun locally, without the wire.
		if e.source == own_pawn do continue
		if !game.sound_audible(listener, e.position, e.range) do continue
		protocol.snapshot_add_sound(s, {kind = e.kind, weapon = e.weapon, position = e.position})
	}
}
