package main

import "../mm"
import "core:log"
import "core:math/rand"
import "core:time"

// The scaling brain. Up: when a region has no joinable server, ask an agent
// with free capacity for one; the pending entry blocks a second spawn while
// the first boots. Down: spawned servers that sat empty past -idle-stop get a
// drain request, as long as the region keeps its -floor of joinable servers.
// Hand-started servers (spawn_id 0) are never touched.

// A drain request the server never acted on escalates to its agent (SIGTERM)
// after this long.
DRAIN_ESCALATE_SECONDS :: 3 * mm.ENTRY_TTL_SECONDS

// True when a spawn is pending or was just initiated for the region -- the
// "Spawning" answer to a client. Empty region means any.
ensure_region_capacity :: proc(region: mm.Region) -> bool {
	for &p in pending {
		if p.active && (region.len == 0 || p.region == region) do return true
	}

	for &a in agents {
		if !a.active do continue
		if region.len != 0 && a.region != region do continue
		if int(a.running) + pending_for_agent(a.agent_id) >= int(a.capacity) do continue

		slot: ^Pending_Spawn
		for &p in pending {
			if !p.active {
				slot = &p
				break
			}
		}
		if slot == nil {
			log.warn("Master: pending-spawn table full")
			return false
		}
		slot^ = {
			active   = true,
			spawn_id = rand.uint64(),
			agent_id = a.agent_id,
			region   = a.region,
			since    = time.tick_now(),
		}

		buf: [mm.MM_MAX_DATAGRAM]u8
		w := mm.writer(buf[:])
		mm.frame_begin(&w, .Spawn_Server)
		mm.write_spawn_server(&w, {token = ms.token, spawn_id = slot.spawn_id})
		master_send(a.ep, buf[:w.off])

		agent_region := a.region
		log.infof(
			"Master: spawning in {} via agent {} (spawn {})",
			mm.region_string(&agent_region),
			a.agent_id,
			slot.spawn_id,
		)
		return true
	}
	return false
}

scale_sweep :: proc() {
	// Floors: every region that has an agent keeps -floor joinable servers
	// warm, so the first player of the day does not wait out a cold boot.
	for &a in agents {
		if !a.active do continue
		first := true
		for &other in agents {
			if !other.active do continue
			if other.region == a.region {
				first = &other == &a
				break
			}
		}
		if !first do continue // one pass per distinct region
		if count_joinable(a.region) < ms.floor {
			ensure_region_capacity(a.region)
		}
	}

	// Drains: spawned, empty past the idle budget, and above the floor.
	for &e in servers {
		if !e.active do continue

		if e.drain_requested {
			// Keep asking until the entry dies (Bye or TTL); a server that
			// ignores us for too long gets stopped through its agent.
			if seconds_since(e.drain_since) > DRAIN_ESCALATE_SECONDS {
				send_stop_server(&e)
			} else {
				send_server_drain(&e)
			}
			continue
		}

		if e.spawn_id == 0 do continue // hand-started servers are not ours to stop
		if !e.joinable || e.draining do continue
		if e.players > 0 do continue
		if seconds_since(e.empty_since) < ms.idle_stop do continue
		if count_joinable(e.region) <= ms.floor do continue

		e.drain_requested = true
		e.drain_since = time.tick_now()
		region := e.region
		log.infof(
			"Master: draining server {} in {} (idle)",
			e.server_id,
			mm.region_string(&region),
		)
		send_server_drain(&e)
	}
}

@(private = "file")
count_joinable :: proc(region: mm.Region) -> int {
	n := 0
	for &e in servers {
		if !e.active do continue
		if e.region != region do continue
		if !e.joinable || e.draining || e.drain_requested do continue
		n += 1
	}
	return n
}

@(private = "file")
send_server_drain :: proc(e: ^Server_Entry) {
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Server_Drain)
	mm.write_server_drain(&w, {token = ms.token, server_id = e.server_id})
	master_send(e.hb_ep, buf[:w.off])
}

@(private = "file")
send_stop_server :: proc(e: ^Server_Entry) {
	a := find_agent_by_id(e.agent_id)
	if a == nil do return // agent gone; the TTL will reap the entry eventually
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Stop_Server)
	mm.write_stop_server(&w, {token = ms.token, server_id = e.server_id})
	master_send(a.ep, buf[:w.off])
}
