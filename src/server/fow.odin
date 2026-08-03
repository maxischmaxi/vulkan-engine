package main

import "../game"
import "../protocol"
import "core:time"

// Fog of war: which pawns each client is told about at all.
//
// The wallhack is the one cheat a server cannot detect, because a client that
// receives an enemy's position is entitled to it -- the aim detectors in
// anticheat/ catch aim bots and can never catch someone who merely knows where
// everyone is. The only structural answer is not to send it.
//
// Hearing is deliberately not filtered through here: sound events go out by
// earshot (server/sound.odin), so an enemy you cannot see is still an enemy you
// can hear.

// How long a pawn keeps being sent after the last sight line broke. Two things
// need it, and the second matters more:
//
//   - a player edging a corner would otherwise flicker in and out every tick
//   - the client renders INTERP_TICKS behind and lerps between two snapshots,
//     so it needs the pawn present in *both* ends of the pair or the motion
//     tears; the linger covers several times that gap
FOW_LINGER_TICKS :: u32(32) // ~0.5 s at 64 Hz
#assert(FOW_LINGER_TICKS > u32(protocol.INTERP_TICKS) * 3)

// Server tick at which each client last had a sight line to each pawn. Zero
// means never.
last_seen: [MAX_CLIENTS][game.MAX_PAWNS]u32

// Cost and outcome of the visibility pass over the last stats window. The cost
// so the raycast bill is visible rather than guessed at; the outcome because
// "nobody was ever visible" and "the filter is broken" produce the same empty
// snapshots, and only a hit count tells them apart.
fow_time: time.Duration
fow_rays: int
fow_seen: int // enemy checks that found a sight line
fow_linger: int // and those carried only by the linger

fow_reset_client :: proc(client: int) {
	if client < 0 || client >= MAX_CLIENTS do return
	for &t in last_seen[client] do t = 0
}

// Which pawns this client may know about this tick.
//
// A dead client is shown everything: it has no eyes to test from, and a
// spectating player who sees nothing is watching a black screen. That is a
// ghosting channel -- a corpse on voice comms telling a live teammate where
// the enemy is -- and counter-strike lives with the same one.
fow_present_mask :: proc(client: int, slot: ^Client_Slot, full: protocol.Present_Mask) -> protocol.Present_Mask {
	if client < 0 || client >= MAX_CLIENTS do return full

	viewer := &sv.gs.pawns[slot.pawn_id]
	if !viewer.active || !viewer.alive do return full

	start := time.tick_now()
	defer fow_time += time.tick_since(start)

	visible: protocol.Present_Mask
	eye := game.eye_position(viewer^)

	for id in 0 ..< game.MAX_PAWNS {
		if id not_in full do continue

		// Yourself and your own team, always: teammates are on your radar and
		// on your minimap anyway, and hiding them would cost far more in
		// playability than it could ever buy in secrecy.
		p := &sv.gs.pawns[id]
		if id == slot.pawn_id || p.team == viewer.team {
			visible += {id}
			continue
		}

		fow_rays += 1
		if game.pawn_visible(&sv.gs, eye, p^) {
			last_seen[client][id] = sv.tick
			visible += {id}
			fow_seen += 1
			continue
		}

		// Out of sight, but not yet out of mind.
		seen := last_seen[client][id]
		if seen != 0 && sv.tick - seen <= FOW_LINGER_TICKS {
			visible += {id}
			fow_linger += 1
		}
	}

	return visible
}

// A pawn left the world (death is not enough -- a corpse is still worth
// seeing; this is for a disconnect or a slot being recycled). Clearing the
// stamp stops the next occupant of that pawn id inheriting a linger.
fow_pawn_removed :: proc(pawn_id: int) {
	if pawn_id < 0 || pawn_id >= game.MAX_PAWNS do return
	for client in 0 ..< MAX_CLIENTS {
		last_seen[client][pawn_id] = 0
	}
}
