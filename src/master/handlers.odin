package main

import "../mm"
import "../protocol"
import "core:log"
import "core:net"
import "core:time"

// Datagram dispatch. Authenticated messages (servers, agents) are checked
// against the shared token and silently dropped on mismatch; client queries
// carry no token and are answered only with what servers advertise anyway.

dispatch :: proc(ep: net.Endpoint, data: []u8) {
	r, msg, ok := mm.frame_open(data)
	if !ok do return

	#partial switch msg {
	case .Server_Heartbeat:
		if m, mok := mm.read_server_heartbeat(&r); mok && m.token == ms.token {
			upsert_server(m, ep)
		}

	case .Server_Bye:
		if m, mok := mm.read_server_bye(&r); mok && m.token == ms.token {
			if e := find_server_by_id(m.server_id); e != nil {
				log.infof("Master: server {} said bye", m.server_id)
				e.active = false
			}
		}

	case .Agent_Heartbeat:
		if m, mok := mm.read_agent_heartbeat(&r); mok && m.token == ms.token {
			upsert_agent(m, ep)
		}

	case .Spawn_Result:
		if m, mok := mm.read_spawn_result(&r); mok && m.token == ms.token {
			if !m.ok {
				log.warnf("Master: spawn {} failed at the agent", m.spawn_id)
				pending_clear(m.spawn_id)
			}
		}

	case .Find_Server:
		if m, mok := mm.read_find_server(&r); mok {
			handle_find(m, ep)
		}

	case .Queue_Enter:
		if m, mok := mm.read_queue_enter(&r); mok {
			handle_queue_enter(m, ep)
		}

	case .Queue_Leave:
		if m, mok := mm.read_queue_leave(&r); mok {
			handle_queue_leave(m, ep)
		}
	}
}

@(private = "file")
upsert_agent :: proc(m: mm.Agent_Heartbeat, ep: net.Endpoint) {
	a := find_agent_by_id(m.agent_id)
	if a == nil {
		for &slot in agents {
			if !slot.active {
				a = &slot
				break
			}
		}
		if a == nil {
			log.warn("Master: agent table full, dropping a heartbeat")
			return
		}
		a^ = {
			active   = true,
			agent_id = m.agent_id,
		}
		region := m.region
		log.infof(
			"Master: agent {} region {} capacity {} running {}",
			m.agent_id,
			mm.region_string(&region),
			m.capacity,
			m.running,
		)
	}
	a.region = m.region
	a.capacity = m.capacity
	a.running = m.running
	a.ep = ep
	a.last_seen = time.tick_now()
}

// The client's question: a joinable server in this region, please. No
// candidate triggers a spawn and answers Spawning -- the client keeps
// retrying, and a couple of seconds later the fresh server's first heartbeat
// flips the answer to Ok.
@(private = "file")
handle_find :: proc(m: mm.Find_Server, ep: net.Endpoint) {
	resp := mm.Find_Response {
		nonce = m.nonce,
	}

	if m.game_version != protocol.PROTOCOL_VERSION {
		// A server this master knows runs the version this master was built
		// with; an incompatible client would only bounce off the handshake.
		resp.status = .No_Capacity
		send_find_response(ep, resp)
		return
	}

	best: ^Server_Entry
	for &e in servers {
		if !e.active do continue
		if e.mode != m.mode do continue
		if m.region.len != 0 && e.region != m.region do continue
		if !e.joinable || e.draining || e.drain_requested do continue
		if e.players >= e.max_players do continue
		if server_reserved(&e) do continue
		// Seats the queue already promised are not quickplay's to take.
		if held_seats(e.server_id) > 0 do continue
		kind_bit := e.addr.kind == .Udp ? mm.ACCEPT_UDP : mm.ACCEPT_STEAM
		if m.accepts & kind_bit == 0 do continue
		// Fill first: the fullest joinable server keeps the fleet dense.
		if best == nil || e.players > best.players do best = &e
	}

	if best != nil {
		// The reservation keeps two concurrent queries off the same instance
		// until its heartbeat reflects the first joiner. It lapses harmlessly
		// if the client never shows.
		best.reserved_at = time.tick_now()
		resp.status = .Ok
		resp.addr = best.addr
		region := best.region
		log.infof(
			"Master: sending a client to server {} in {}",
			best.server_id,
			mm.region_string(&region),
		)
	} else {
		resp.status = ensure_region_capacity(m.region, m.mode) ? .Spawning : .No_Capacity
	}
	send_find_response(ep, resp)
}

@(private = "file")
send_find_response :: proc(ep: net.Endpoint, resp: mm.Find_Response) {
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Find_Response)
	mm.write_find_response(&w, resp)
	master_send(ep, buf[:w.off])
}
