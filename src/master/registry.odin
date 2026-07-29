package main

import "../mm"
import "core:log"
import "core:net"
import "core:time"

// The registry: fixed tables of everything that heartbeats at us. Entries die
// by TTL when the heartbeats stop -- crash cleanup and state repair are the
// same code path. Overflow logs and drops, in the codebase's bounded-tables
// tradition.

MAX_SERVERS :: 64
MAX_AGENTS :: 16
MAX_PENDING :: 16

Server_Entry :: struct {
	active:          bool,
	server_id:       u64,
	spawn_id:        u64, // 0 = hand-started; only spawned servers get drained
	agent_id:        u64, // who spawned it (0 when unknown); the Stop escalation target
	region:          mm.Region,
	addr:            mm.Server_Addr,
	hb_ep:           net.Endpoint, // where Server_Drain goes
	players:         u8,
	max_players:     u8,
	joinable:        bool,
	draining:        bool, // server-reported
	drain_requested: bool, // we asked; resent every sweep until the entry dies
	drain_since:     time.Tick,
	reserved_at:     time.Tick, // last Find_Response Ok naming this server
	empty_since:     time.Tick, // last moment the server reported players > 0
	last_seen:       time.Tick,
}

Agent_Entry :: struct {
	active:    bool,
	agent_id:  u64,
	region:    mm.Region,
	capacity:  u8,
	running:   u8,
	ep:        net.Endpoint,
	last_seen: time.Tick,
}

// A spawn in flight: counts against the agent's capacity until the child's
// first heartbeat clears it (or the timeout declares the boot failed). This is
// the double-spawn guard.
Pending_Spawn :: struct {
	active:   bool,
	spawn_id: u64,
	agent_id: u64,
	region:   mm.Region,
	since:    time.Tick,
}

servers: [MAX_SERVERS]Server_Entry
agents: [MAX_AGENTS]Agent_Entry
pending: [MAX_PENDING]Pending_Spawn

seconds_since :: proc(t: time.Tick) -> f64 {
	return time.duration_seconds(time.tick_since(t))
}

server_reserved :: proc(e: ^Server_Entry) -> bool {
	return seconds_since(e.reserved_at) < mm.RESERVE_SECONDS
}

find_server_by_id :: proc(server_id: u64) -> ^Server_Entry {
	for &e in servers {
		if e.active && e.server_id == server_id do return &e
	}
	return nil
}

find_agent_by_id :: proc(agent_id: u64) -> ^Agent_Entry {
	for &a in agents {
		if a.active && a.agent_id == agent_id do return &a
	}
	return nil
}

upsert_server :: proc(m: mm.Server_Heartbeat, ep: net.Endpoint) {
	now := time.tick_now()

	// A Udp server that advertised no address gets the datagram's source IP:
	// correct whenever clients sit on the same side of the network as we do,
	// and -advertise= is the escape hatch when they do not.
	addr := m.addr
	if addr.kind == .Udp && addr.ip4 == {0, 0, 0, 0} {
		if ip4, ok := ep.address.(net.IP4_Address); ok {
			addr.ip4 = transmute([4]u8)ip4
		}
	}

	e := find_server_by_id(m.server_id)
	if e == nil {
		for &slot in servers {
			if !slot.active {
				e = &slot
				break
			}
		}
		if e == nil {
			log.warn("Master: server table full, dropping a heartbeat")
			return
		}
		e^ = {
			active      = true,
			server_id   = m.server_id,
			spawn_id    = m.spawn_id,
			empty_since = now,
		}
		if m.spawn_id != 0 {
			e.agent_id = pending_clear(m.spawn_id)
		}
		region := m.region
		log.infof(
			"Master: server {} up in {} ({})",
			m.server_id,
			mm.region_string(&region),
			addr_desc(addr),
		)
	}

	e.region = m.region
	e.addr = addr
	e.hb_ep = ep
	e.players = m.players
	e.max_players = m.max_players
	e.joinable = m.joinable
	e.draining = m.draining
	if m.players > 0 do e.empty_since = now
	e.last_seen = now
}

// Returns the agent that owned the pending spawn, so the server entry knows
// whom a Stop_Server escalation must go to.
pending_clear :: proc(spawn_id: u64) -> u64 {
	for &p in pending {
		if p.active && p.spawn_id == spawn_id {
			p.active = false
			return p.agent_id
		}
	}
	return 0
}

pending_for_agent :: proc(agent_id: u64) -> int {
	n := 0
	for &p in pending {
		if p.active && p.agent_id == agent_id do n += 1
	}
	return n
}

registry_sweep :: proc() {
	for &e in servers {
		if !e.active do continue
		if seconds_since(e.last_seen) > mm.ENTRY_TTL_SECONDS {
			region := e.region
			log.infof(
				"Master: server {} in {} went silent, dropping",
				e.server_id,
				mm.region_string(&region),
			)
			e.active = false
		}
	}
	for &a in agents {
		if !a.active do continue
		if seconds_since(a.last_seen) > mm.ENTRY_TTL_SECONDS {
			region := a.region
			log.infof(
				"Master: agent {} in {} went silent, dropping",
				a.agent_id,
				mm.region_string(&region),
			)
			a.active = false
		}
	}
	for &p in pending {
		if !p.active do continue
		if seconds_since(p.since) > mm.SPAWN_TIMEOUT_SECONDS {
			log.warnf("Master: spawn {} never came up, freeing the slot", p.spawn_id)
			p.active = false
		}
	}
}

addr_desc :: proc(addr: mm.Server_Addr) -> string {
	switch addr.kind {
	case .Steam:
		return "steam"
	case .Udp:
		return "udp"
	}
	return "?"
}
