package main

import "../game"
import "../mm"
import "core:log"
import "core:math/rand"
import "core:net"

// The server's face toward the master: a 2-second heartbeat carrying identity,
// region, occupancy and joinability, on a dedicated control socket that exists
// in every build (STEAM_REQUIRED compiles out the game's UDP listener, not
// this). The master is optional -- no -master flag, no traffic -- and losing
// it is survivable by design: heartbeats just go unanswered until it returns.
//
// The same socket receives Server_Drain, the master's scale-down request:
// refuse new joins, exit once empty.

HEARTBEAT_TICKS :: u32(mm.HEARTBEAT_SECONDS * game.TICK_RATE)

hb: struct {
	enabled:       bool,
	socket:        net.UDP_Socket,
	master_str:    string, // the -master= flag, resolved in heartbeat_init
	master_ep:     net.Endpoint,
	region:        mm.Region,
	token:         mm.Token,
	server_id:     u64,
	spawn_id:      u64, // non-zero only when an agent spawned us (-server-id)
	port:          u16, // the game port, what a Udp addr advertises
	advertise:     net.Endpoint, // -advertise= override for NAT-split setups
	has_advertise: bool,
	draining:      bool, // master asked us to wind down
	last_sig:      u32, // packed status; a change sends off-cadence
}

heartbeat_init :: proc() -> bool {
	if hb.master_str == "" do return true

	ep, ok := net.parse_endpoint(hb.master_str)
	if !ok {
		resolved, err := net.resolve_ip4(hb.master_str)
		if err != nil {
			log.errorf("Server: cannot resolve -master={}: {}", hb.master_str, err)
			return false
		}
		ep = resolved
	}
	if ep.port == 0 do ep.port = mm.MM_DEFAULT_PORT
	hb.master_ep = ep

	socket, serr := net.make_bound_udp_socket(net.IP4_Any, 0)
	if serr != nil {
		log.errorf("Server: cannot open the control socket: {}", serr)
		return false
	}
	if berr := net.set_blocking(socket, false); berr != nil {
		log.errorf("Server: cannot make the control socket non-blocking: {}", berr)
		net.close(socket)
		return false
	}
	hb.socket = socket

	if hb.region.len == 0 do hb.region = mm.region_from_string("local")
	if hb.server_id == 0 do hb.server_id = rand.uint64()

	hb.enabled = true
	log.infof(
		"Server: heartbeat to {} (region {}, id {})",
		net.to_string(hb.master_ep),
		mm.region_string(&hb.region),
		hb.server_id,
	)
	return true
}

// Called once per tick, after the snapshots went out.
heartbeat_tick :: proc() {
	if !hb.enabled do return

	heartbeat_receive()

	// The master only drains empty servers, so this fires within a tick of the
	// request in practice; the guard also covers a straggler leaving later.
	if hb.draining && !shutting_down() && count_clients() == 0 {
		begin_shutdown()
	}

	// After the bye went out, more heartbeats would only resurrect the entry.
	if shutting_down() do return

	joinable := match.phase == .Idle && !hb.draining
	sig :=
		u32(count_clients()) |
		u32(match.phase) << 8 |
		(joinable ? 1 << 16 : 0) |
		(hb.draining ? 1 << 17 : 0)
	if sig == hb.last_sig && sv.tick % HEARTBEAT_TICKS != 0 do return
	hb.last_sig = sig

	addr: mm.Server_Addr
	when STEAM_REQUIRED {
		// Before the anonymous logon confirms there is no SteamID, hence no
		// address to advertise; the master learns about us once there is.
		if !steam_sv.logged_on do return
		addr = {
			kind     = .Steam,
			steam_id = steam_server_id(),
		}
	} else {
		// Dev servers advertise their UDP endpoint even when Steam is up: the
		// local fleet is a UDP world, --connect covers manual Steam testing.
		addr = {
			kind = .Udp,
			port = hb.port,
		}
		if hb.has_advertise {
			if ip4, aok := hb.advertise.address.(net.IP4_Address); aok {
				addr.ip4 = transmute([4]u8)ip4
			}
			addr.port = u16(hb.advertise.port)
		}
	}

	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Server_Heartbeat)
	mm.write_server_heartbeat(
		&w,
		{
			token = hb.token,
			server_id = hb.server_id,
			spawn_id = hb.spawn_id,
			region = hb.region,
			addr = addr,
			players = u8(count_clients()),
			max_players = MAX_CLIENTS,
			phase = u8(match.phase),
			joinable = joinable,
			draining = hb.draining,
		},
	)
	heartbeat_send(buf[:w.off])
}

// Redundant goodbyes on graceful exit: the entry dies now, not at TTL. Loss of
// all three still only costs the master a TTL sweep.
heartbeat_bye :: proc() {
	if !hb.enabled do return
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Server_Bye)
	mm.write_server_bye(&w, {token = hb.token, server_id = hb.server_id})
	for _ in 0 ..< 3 {
		heartbeat_send(buf[:w.off])
	}
}

// New handshakes are refused while winding down; connected players are never
// cut by a drain (the master only drains empty servers anyway).
server_refusing_joins :: proc() -> bool {
	return hb.draining || shutting_down()
}

count_clients :: proc() -> int {
	n := 0
	for &slot in clients {
		if slot.state != .Empty do n += 1
	}
	return n
}

@(private = "file")
heartbeat_receive :: proc() {
	buf: [mm.MM_MAX_DATAGRAM]u8
	for {
		n, ep, err := net.recv_udp(hb.socket, buf[:])
		if err == .Would_Block do break
		if err != nil {
			log.warnf("Server: control socket recv error {}", err)
			break
		}
		// Only the master we heartbeat to may speak here.
		if ep != hb.master_ep do continue
		r, msg, ok := mm.frame_open(buf[:n])
		if !ok || msg != .Server_Drain do continue
		m, mok := mm.read_server_drain(&r)
		if !mok || m.token != hb.token || m.server_id != hb.server_id do continue
		if !hb.draining {
			hb.draining = true
			log.info("Server: drain requested by master")
		}
	}
}

@(private = "file")
heartbeat_send :: proc(data: []u8) {
	if _, err := net.send_udp(hb.socket, data, hb.master_ep); err != nil {
		log.warnf("Server: control socket send error {}", err)
	}
}
