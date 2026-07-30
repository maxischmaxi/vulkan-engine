package main

import "../game"
import "../mm"
import "../protocol"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:time"

// The matchmaking queue: a bounded table of waiting players, grouped by
// (mode, region), FIFO by enqueue time. There is deliberately no Lobby
// object -- formation is an event, not a thing: once a group crosses the
// -min-humans threshold it is assigned to a server, and from then on the
// server's own heartbeat (players, joinable, mode) is the source of truth.
// Later queuers backfill a warmup that still has seats; "waiting for a
// server to boot" is simply queued entries plus a mode-matching pending
// spawn, so a failed spawn needs no requeue logic at all.
//
// Identity is (endpoint, nonce), the Find_Server trust model: no accounts,
// no tickets. Queue_Enter doubles as heartbeat and as idempotent re-entry
// after a master restart.

MAX_QUEUED :: 128

Queue_State :: enum u8 {
	Queued, // waiting in the pool
	Assigned, // Match_Assign sent; lingers for seat accounting and re-answer
}

Queue_Entry :: struct {
	active:      bool,
	state:       Queue_State,
	ep:          net.Endpoint,
	nonce:       u32,
	mode:        game.Mode,
	region:      mm.Region,
	accepts:     u8,
	enqueued_at: time.Tick, // FIFO order and the log's wait-time source
	last_seen:   time.Tick, // TTL: QUEUE_TTL_SECONDS
	// Assigned only:
	server_id:   u64,
	match_id:    u64,
	assigned_at: time.Tick, // the seat is held until ASSIGN_GRACE_SECONDS pass
}

queue: [MAX_QUEUED]Queue_Entry

handle_queue_enter :: proc(m: mm.Queue_Enter, ep: net.Endpoint) {
	if m.game_version != protocol.PROTOCOL_VERSION {
		send_queue_reply(ep, {nonce = m.nonce, status = .Bad_Version})
		return
	}

	now := time.tick_now()
	e := queue_find(ep, m.nonce)
	if e == nil {
		for &slot in queue {
			if !slot.active {
				e = &slot
				break
			}
		}
		if e == nil {
			// Bounded-tables tradition: log and drop. The client keeps
			// resending and gets in when a slot frees.
			log.warn("Master: queue table full, dropping an enter")
			return
		}
		e^ = {
			active      = true,
			state       = .Queued,
			ep          = ep,
			nonce       = m.nonce,
			enqueued_at = now,
		}
		region := m.region
		log.infof(
			"Master: queue enter {} mode {} region {}",
			m.nonce,
			m.mode,
			mm.region_string(&region),
		)
	}
	e.mode = m.mode
	e.region = m.region
	e.accepts = m.accepts
	e.last_seen = now

	if e.state == .Assigned {
		// The reliability loop: keep answering with the assignment while the
		// server still exists; a dead server puts the entry back in the pool
		// with its ORIGINAL enqueue time, keeping first-come-first-served
		// honest.
		if server := find_server_by_id(e.server_id); server != nil {
			send_match_assign(e, server)
			return
		}
		e.state = .Queued
	}

	status := queue_match_make(e.mode, e.region)
	// The match maker may just have assigned this very entry; only answer
	// with a waiting status if it is still waiting.
	if e.state == .Queued {
		queued, needed := queue_group_size(e.mode, e.region)
		send_queue_reply(
			ep,
			{nonce = e.nonce, status = status, queued = u8(min(queued, 255)), needed = u8(needed)},
		)
	}
}

handle_queue_leave :: proc(m: mm.Queue_Leave, ep: net.Endpoint) {
	e := queue_find(ep, m.nonce)
	if e == nil do return
	log.infof(
		"Master: queue leave {} after {:.0f}s",
		e.nonce,
		seconds_since(e.enqueued_at),
	)
	e.active = false
}

// The assembly brain, called on every enter and once per sweep per distinct
// (mode, region) group. Three steps, first hit wins:
//   1. backfill: a live warmup of this mode with free seats takes the oldest
//      queuers right away, threshold or not
//   2. formation: enough queued humans plus a fresh idle server start a match
//   3. no server: spawn one (Spawning) or admit there is none (No_Capacity)
queue_match_make :: proc(mode: game.Mode, region: mm.Region) -> mm.Queue_Status {
	// 1. backfill into servers that already hold players
	if server := queue_pick_server(mode, region, true); server != nil {
		queue_assign_batch(server, mode, region, 0)
		return .Queued
	}

	// 2. formation on a fresh server
	queued, needed := queue_group_size(mode, region)
	if queued < needed do return .Queued

	if server := queue_pick_server(mode, region, false); server != nil {
		match_id := rand.uint64()
		assigned := queue_assign_batch(server, mode, region, match_id)
		log.infof(
			"Master: match {} formed -- {} human(s), mode {}, server {}",
			match_id,
			assigned,
			mode,
			server.server_id,
		)
		return .Queued
	}

	// 3. no server exists: get one booting
	if ensure_region_capacity(region, mode, u8(min(queued, game.mode_max_humans(mode)))) {
		return .Spawning
	}
	return .No_Capacity
}

// Once per master sweep: expire silent entries, then give every waiting
// group a chance (a fresh server's first heartbeat arrives between enters).
queue_sweep :: proc() {
	for &e in queue {
		if !e.active do continue
		if seconds_since(e.last_seen) > mm.QUEUE_TTL_SECONDS {
			log.infof("Master: queue entry {} went silent, dropping", e.nonce)
			e.active = false
		}
	}
	for &e in queue {
		if !e.active || e.state != .Queued do continue
		first := true
		for &other in queue {
			if !other.active || other.state != .Queued do continue
			if other.mode == e.mode && other.region == e.region {
				first = &other == &e
				break
			}
		}
		if first {
			queue_match_make(e.mode, e.region)
		}
	}
}

// Seats already promised to assigned players who have not shown up in the
// server's player count yet. Conservative: a player who connects fast is
// briefly counted twice, which can only under-fill, never double-book.
held_seats :: proc(server_id: u64) -> int {
	n := 0
	for &e in queue {
		if !e.active || e.state != .Assigned do continue
		if e.server_id != server_id do continue
		if seconds_since(e.assigned_at) < mm.ASSIGN_GRACE_SECONDS do n += 1
	}
	return n
}

@(private = "file")
queue_find :: proc(ep: net.Endpoint, nonce: u32) -> ^Queue_Entry {
	for &e in queue {
		if e.active && e.nonce == nonce && e.ep == ep do return &e
	}
	return nil
}

@(private = "file")
queue_group_size :: proc(mode: game.Mode, region: mm.Region) -> (queued, needed: int) {
	for &e in queue {
		if e.active && e.state == .Queued && e.mode == mode && e.region == region do queued += 1
	}
	return queued, max(ms.min_humans, 1)
}

// A server the queue may put players on. occupied selects between the
// backfill pass (someone is already in: a live warmup) and the formation
// pass (a fresh, idle instance).
@(private = "file")
queue_pick_server :: proc(mode: game.Mode, region: mm.Region, occupied: bool) -> ^Server_Entry {
	best: ^Server_Entry
	for &e in servers {
		if !e.active do continue
		if e.mode != mode do continue
		if region.len != 0 && e.region != region do continue
		if !e.joinable || e.draining || e.drain_requested do continue
		seated := int(e.players) + held_seats(e.server_id)
		if seated >= int(e.max_players) do continue
		if occupied != (seated > 0) do continue
		// Fill first, like the Find path: the fullest candidate keeps the
		// fleet dense.
		if best == nil || e.players > best.players do best = &e
	}
	return best
}

// Hands the oldest queued entries of the group to the server, as many as it
// has free seats. Returns how many were assigned.
@(private = "file")
queue_assign_batch :: proc(
	server: ^Server_Entry,
	mode: game.Mode,
	region: mm.Region,
	match_id: u64,
) -> int {
	assigned := 0
	for {
		free := int(server.max_players) - int(server.players) - held_seats(server.server_id)
		if free <= 0 do break

		oldest: ^Queue_Entry
		for &e in queue {
			if !e.active || e.state != .Queued do continue
			if e.mode != mode || e.region != region do continue
			kind_bit := server.addr.kind == .Udp ? mm.ACCEPT_UDP : mm.ACCEPT_STEAM
			if e.accepts & kind_bit == 0 do continue
			if oldest == nil || time.tick_since(e.enqueued_at) > time.tick_since(oldest.enqueued_at) {
				oldest = &e
			}
		}
		if oldest == nil do break

		oldest.state = .Assigned
		oldest.server_id = server.server_id
		oldest.match_id = match_id
		oldest.assigned_at = time.tick_now()
		send_match_assign(oldest, server)
		log.infof(
			"Master: assigned {} to server {} after {:.0f}s in queue",
			oldest.nonce,
			server.server_id,
			seconds_since(oldest.enqueued_at),
		)
		assigned += 1
	}
	return assigned
}

@(private = "file")
send_match_assign :: proc(e: ^Queue_Entry, server: ^Server_Entry) {
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Match_Assign)
	mm.write_match_assign(&w, {nonce = e.nonce, match_id = e.match_id, addr = server.addr})
	master_send(e.ep, buf[:w.off])
}

@(private = "file")
send_queue_reply :: proc(ep: net.Endpoint, m: mm.Queue_Reply) {
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Queue_Reply)
	mm.write_queue_reply(&w, m)
	master_send(ep, buf[:w.off])
}
