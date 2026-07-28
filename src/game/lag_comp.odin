package game

// Server-side lag compensation. The client aims at remote entities rendered a
// fixed interpolation delay behind the newest snapshot, so the server rewinds
// everyone else's hitbox to that moment before resolving a human's shot. Pure
// simulation state, which is why it lives here and not in the server binary:
// the whole rewind is testable without a socket.

LAG_HISTORY_TICKS :: 64 // one second at 64 Hz

// How far back a shot may rewind (~250 ms): bounds both the advantage of a
// high-ping player and what a modified client can claim to have seen.
MAX_REWIND_TICKS :: 16

// What a hitbox rewind needs and nothing more: where the pawn stood, the hull
// it had (crouching shrinks it), and whether it could be hit at all.
Lag_Record :: struct {
	position: [3]f32,
	radius:   f32,
	height:   f32,
	alive:    bool,
}

Lag_History :: struct {
	ticks:   [LAG_HISTORY_TICKS]u32,
	records: [LAG_HISTORY_TICKS][MAX_PAWNS]Lag_Record,
}

// Recorded at the end of a server tick, after everything moved: history[N]
// must equal what snapshot N told the clients. That agreement is the property
// the whole rewind rests on.
lag_history_record :: proc(h: ^Lag_History, gs: ^Game_State, tick: u32) {
	idx := tick % LAG_HISTORY_TICKS
	h.ticks[idx] = tick
	for &p, i in gs.pawns {
		h.records[idx][i] = {
			position = p.body.position,
			radius   = p.body.radius,
			height   = p.body.height,
			alive    = p.active && p.alive,
		}
	}
}

// Exact-tick match only: a ring slot holding some other tick is no baseline.
lag_history_has :: proc(h: ^Lag_History, tick: u32) -> bool {
	return tick != 0 && h.ticks[tick % LAG_HISTORY_TICKS] == tick
}

// The undo state for one rewound shot.
Rewind :: struct {
	saved:       [MAX_PAWNS]Lag_Record,
	rewound:     [MAX_PAWNS]bool,
	forced_dead: [MAX_PAWNS]bool,
}

// Moves every pawn except the shooter to where it stood at `tick`. A pawn not
// alive back then is hidden from the trace instead -- never the reverse:
// corpses are neither targets nor shields, and a pawn dead now cannot be hit
// no matter where it used to stand.
lag_comp_begin :: proc(
	h: ^Lag_History,
	gs: ^Game_State,
	tick: u32,
	shooter: int,
) -> (
	rw: Rewind,
	ok: bool,
) {
	if !lag_history_has(h, tick) do return
	recs := &h.records[tick % LAG_HISTORY_TICKS]

	for &p, i in gs.pawns {
		if i == shooter || !p.active do continue
		rw.saved[i] = {
			position = p.body.position,
			radius   = p.body.radius,
			height   = p.body.height,
		}
		rec := recs[i]
		if rec.alive && p.alive {
			p.body.position = rec.position
			p.body.radius = rec.radius
			p.body.height = rec.height
			rw.rewound[i] = true
		} else if !rec.alive && p.alive {
			p.alive = false
			rw.forced_dead[i] = true
		}
	}
	return rw, true
}

// Restores the hulls and un-hides pawns. Damage dealt inside the rewind --
// health, a kill, the zeroed velocity -- deliberately stays.
lag_comp_end :: proc(gs: ^Game_State, rw: ^Rewind) {
	for &p, i in gs.pawns {
		if rw.rewound[i] {
			p.body.position = rw.saved[i].position
			p.body.radius = rw.saved[i].radius
			p.body.height = rw.saved[i].height
		}
		if rw.forced_dead[i] {
			p.alive = true
		}
	}
}
