package main

import "core:log"
import "core:math"
import "core:math/rand"
import "core:net"
import "core:time"
import "game"
import "protocol"

// The client's end of the wire: the handshake, the receive pump, the snapshot
// ring, the mirrored match state. Prediction and interpolation read from here;
// nothing here touches the renderer.

// Ring depth is a protocol constant: the server may only pick delta baselines
// this ring still holds.
SNAPSHOT_CAP :: protocol.SNAPSHOT_RING

NET_CONNECT_TIMEOUT :: 5.0
// Finding a relay route can take well over the loopback budget.
NET_CONNECT_TIMEOUT_STEAM :: 15.0
NET_SNAPSHOT_TIMEOUT :: 5.0

Net_Transport :: enum u8 {
	Udp,
	Steam,
}

// How far ahead of the server's clock the client stamps its commands, so they
// arrive just before the tick that wants them. Generous for localhost; a real
// link would tune this from the measured round trip.
NET_RUN_AHEAD :: 8

Net_Client :: struct {
	active:             bool, // socket open, somewhere in the handshake or beyond
	transport:          Net_Transport,
	got_accept:         bool,
	joined:             bool, // match joined; snapshots are flowing
	// Registered on the range instead of joining a match. Snapshots still
	// arrive -- they carry the reliable acks and feed the liveness watchdog --
	// but none of their content may touch the locally simulated range.
	practice:           bool,
	socket:             net.UDP_Socket,
	server_ep:          net.Endpoint,
	conn:               protocol.Connection,
	client_salt:        u32,
	pawn_id:            int,
	team:               game.Team,
	connect_start:      time.Tick,
	last_send:          time.Tick,
	last_snapshot_time: time.Tick,
	// ring of full snapshots, keyed by server tick
	snapshots:          [SNAPSHOT_CAP]protocol.Snapshot,
	valid:              [SNAPSHOT_CAP]bool,
	latest_tick:        u32,
	have_snapshot:      bool,
	// the match as the server last described it
	phase:              game.Match_Phase,
	time_left:          f32,
	t_score:            int,
	ct_score:           int,
	// diagnostics for the stats line
	corrections:        int,
	snap_full:          int, // full snapshots since the last stats line
	snap_delta:         int, // delta snapshots since the last stats line
	snap_bytes:         int, // their payload bytes, for the average
	kills_seen:         u8,
	kills_synced:       bool, // first private block seeds kills_seen without a marker
	// Damage message bookkeeping: the health-drop fallback in reconcile only
	// fires when no Damage message covered the drop -- see predict.odin.
	last_damage_tick:   u32,
	last_health_tick:   u32,
}

net_client: Net_Client

recv_buf: [protocol.MTU]u8

net_connect_start :: proc(port: int, team: game.Team) {
	net_connect_start_ep({address = net.IP4_Loopback, port = port}, team)
}

// The general UDP entry: any endpoint, e.g. one the master handed out.
net_connect_start_ep :: proc(server_ep: net.Endpoint, team: game.Team) {
	if !net_open(server_ep) do return
	net_client.team = team
	log.infof("NET: connecting to {}", net.to_string(server_ep))
	send_connect_request()
}

// The practice variant of the handshake: no team, and the accept leads to the
// range instead of waiting for a match phase (see handle_server_packet).
net_practice_start :: proc(port: int) {
	if !net_open({address = net.IP4_Loopback, port = port}) do return
	net_client.practice = true
	log.infof("NET: connecting to 127.0.0.1:{} for practice", port)
	send_connect_request()
}

// The Steam variant: no socket -- a P2P connection to the server's SteamID.
// The Connect_Request waits until Steam reports the route open and the auth
// ticket is in hand; net_try_connect_request fires it from either callback.
net_connect_start_steam :: proc(steamid: u64, team: game.Team) {
	if !steam_available() {
		scene.error_text = "STEAM NOT RUNNING"
		enter_scene(.Menu)
		return
	}
	net_reset()
	net_client.active = true
	net_client.transport = .Steam
	net_client.team = team
	net_client.client_salt = rand.uint32()
	net_client.connect_start = time.tick_now()
	net_client.last_send = time.tick_now()
	net_client.phase = .Idle
	steam_request_ticket(steamid)
	steam_net_connect(steamid)
	log.infof("NET: connecting to steam server {}", steamid)
}

// Sends the connect request if everything it depends on is ready; safe to
// call from every place that removes one of the obstacles.
net_try_connect_request :: proc() {
	if !net_client.active || net_client.got_accept do return
	if net_client.transport == .Steam {
		if !steam_net.connected || !steam_state.ticket_ready do return
	}
	send_connect_request()
}

@(private = "file")
net_open :: proc(server_ep: net.Endpoint) -> bool {
	net_reset()

	socket, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("NET: cannot open a socket: {}", err)
		scene.error_text = "CANNOT OPEN A SOCKET"
		enter_scene(.Menu)
		return false
	}
	if block_err := net.set_blocking(socket, false); block_err != nil {
		log.errorf("NET: cannot make the socket non-blocking: {}", block_err)
		net.close(socket)
		scene.error_text = "CANNOT OPEN A SOCKET"
		enter_scene(.Menu)
		return false
	}

	net_client.active = true
	net_client.socket = socket
	net_client.server_ep = server_ep
	net_client.client_salt = rand.uint32()
	net_client.connect_start = time.tick_now()
	net_client.phase = .Idle
	return true
}

// Best effort: tell the server we are gone, then forget it. Called from every
// path that leaves the networked game, so it must be safe to call twice.
net_disconnect :: proc() {
	if !net_client.active do return

	if net_client.got_accept {
		for _ in 0 ..< 3 {
			buf: [64]u8
			w := protocol.writer(buf[:])
			protocol.connection_begin_packet(&net_client.conn, &w)
			protocol.write_u8(&w, u8(protocol.Msg_Id.Disconnect))
			protocol.write_disconnect(&w, {reason = .Quit})
			net_send(w.buf[:w.off])
		}
	}
	switch net_client.transport {
	case .Udp:
		net.close(net_client.socket)
	case .Steam:
		steam_net_close(true) // linger so the Disconnect burst still flushes
		steam_cancel_ticket()
	}
	log.info("NET: disconnected")
	net_reset()
}

@(private = "file")
net_reset :: proc() {
	if net_client.active {
		// the caller closed or is about to close the socket; just forget state
	}
	net_client = {}
	predictor = {}
	remote = {}
}

// Called every frame in every scene: drains the socket, drives the handshake,
// watches the timeouts.
net_client_pump :: proc() {
	if !net_client.active do return
	now := time.tick_now()

	// handshake upkeep
	if !net_client.joined {
		timeout :=
			net_client.transport == .Steam ? NET_CONNECT_TIMEOUT_STEAM : NET_CONNECT_TIMEOUT
		if time.duration_seconds(time.tick_diff(net_client.connect_start, now)) > timeout {
			net_fail("COULD NOT REACH SERVER")
			return
		}
		if time.duration_seconds(time.tick_diff(net_client.last_send, now)) >
		   protocol.CONNECT_RETRY_SECONDS {
			if net_client.got_accept {
				send_keepalive() // carries the queued reliable Join until acked
			} else {
				net_try_connect_request()
			}
		}
	}

	// A practice client sends no input packets, so the keepalive is what feeds
	// the server's timeout and carries the reliable Practice message to its ack.
	if net_client.joined && net_client.practice {
		if time.duration_seconds(time.tick_diff(net_client.last_send, now)) >
		   protocol.CONNECT_RETRY_SECONDS {
			send_keepalive()
		}
	}

	// drain everything that arrived
	switch net_client.transport {
	case .Udp:
		for {
			n, _, err := net.recv_udp(net_client.socket, recv_buf[:])
			if err == .Would_Block do break
			if err != nil {
				log.warnf("NET: recv error {}", err)
				break
			}
			if n < protocol.HEADER_SIZE do continue
			handle_server_packet(recv_buf[:n])
			if !net_client.active do return // a deny or disconnect tore us down
		}
	case .Steam:
		for {
			data, ok := steam_net_poll()
			if !ok do break
			if len(data) < protocol.HEADER_SIZE do continue
			handle_server_packet(data)
			if !net_client.active do return
		}
	}

	// a joined client that stops hearing snapshots has lost the server
	if net_client.joined {
		if time.duration_seconds(time.tick_since(net_client.last_snapshot_time)) >
		   NET_SNAPSHOT_TIMEOUT {
			net_fail("CONNECTION LOST")
		}
	}
}

net_fail :: proc(text: string) {
	log.warnf("NET: {}", text)
	net_disconnect()
	scene.error_text = text
	enter_scene(.Menu)
}

// All strings glyph-safe for the HUD font (uppercase, no ? & ' @).
deny_text :: proc(reason: protocol.Deny_Reason) -> string {
	switch reason {
	case .Full:
		return "SERVER FULL"
	case .Bad_Version:
		return "VERSION MISMATCH"
	case .Bad_Ticket:
		return "STEAM AUTH FAILED"
	case .No_License:
		return "GAME NOT OWNED ON THIS ACCOUNT"
	case .Banned:
		return "BANNED"
	case .Auth_Timeout:
		return "STEAM AUTH TIMED OUT"
	case .None, .In_Match:
	}
	return "CONNECTION REFUSED"
}

server_disconnect_text :: proc(reason: protocol.Disconnect_Reason) -> string {
	#partial switch reason {
	case .Auth_Revoked:
		return "STEAM AUTH REVOKED"
	case .Shutdown:
		return "SERVER SHUT DOWN"
	case .Kicked:
		return "KICKED"
	case .Banned:
		return "BANNED"
	}
	return "SERVER CLOSED THE CONNECTION"
}

@(private = "file")
handle_server_packet :: proc(data: []u8) {
	// Before the accept, the only currency is session-0 handshake packets.
	if !net_client.got_accept {
		scratch: protocol.Connection
		protocol.connection_init(&scratch, 0)
		r, ok := protocol.connection_read(&scratch, data)
		if !ok do return

		id := protocol.Msg_Id(protocol.read_u8(&r))
		#partial switch id {
		case .Connect_Accept:
			accept, aok := protocol.read_connect_accept(&r)
			if !aok do return
			net_client.got_accept = true
			net_client.pawn_id = int(accept.pawn_id)
			net_client.phase = accept.phase
			protocol.connection_init(&net_client.conn, net_client.client_salt ~ accept.server_salt)
			// Commands are stamped ahead of the server's clock so they arrive
			// before the tick that consumes them.
			predictor.input_tick = accept.server_tick + NET_RUN_AHEAD
			log.infof(
				"NET: accepted as pawn {} at server tick {}",
				accept.pawn_id,
				accept.server_tick,
			)
			if net_client.practice {
				// the range flag rides reliably instead of a Join, so the
				// server records the player without starting a match
				if !protocol.queue_reliable_msg(
					&net_client.conn,
					.Practice,
					protocol.write_practice,
					protocol.Practice_Msg{entering = true},
				) {
					net_fail("PROTOCOL FAILURE")
					return
				}
			} else {
				// the team choice rides reliably; the server answers with a phase
				if !protocol.queue_reliable_msg(
					&net_client.conn,
					.Join,
					protocol.write_join,
					protocol.Join{team = net_client.team},
				) {
					net_fail("PROTOCOL FAILURE")
					return
				}
			}
			// the seed loadout ships right behind the join, so --weapon runs
			// spawn armed and the slot never holds a stale default
			net_send_loadout(seed_loadout())
			// debug toggles flipped before connecting still have to arrive
			if debug.god_mode || debug.infinite_ammo {
				net_send_debug_flags()
			}
			when !STEAM_REQUIRED {
				if cli.cheat_probe == "debugmsg" {
					// Deliberately illegal: a hardened server answers this
					// with an instant ban, which is exactly what the headless
					// anti-cheat E2E test wants to observe.
					protocol.queue_reliable_msg(
						&net_client.conn,
						.Debug_Flags,
						protocol.write_debug_flags,
						protocol.Debug_Flags{god = true, infinite_ammo = true},
					)
				}
			}
			send_keepalive()

			if net_client.practice {
				// The accept is the "you are in": the queued Practice message is
				// guaranteed to arrive over the reliable channel, and from here
				// the snapshot watchdog owns connection liveness. The accept may
				// carry another match's phase; the range has none.
				net_client.phase = .Idle
				net_client.joined = true
				net_client.last_snapshot_time = time.tick_now()
				enter_scene(.Practice)
			}

		case .Connect_Deny:
			deny, dok := protocol.read_connect_deny(&r)
			reason := dok ? deny.reason : .None
			log.warnf("NET: connection denied ({})", reason)
			net_disconnect()
			scene.error_text = deny_text(reason)
			enter_scene(.Menu)
		}
		return
	}

	r, ok := protocol.connection_read(&net_client.conn, data)
	if !ok do return

	// reliable control messages, in order
	for i in 0 ..< net_client.conn.incoming_count {
		msg := &net_client.conn.incoming[i]
		payload := protocol.reader(msg.payload[:msg.size])
		#partial switch msg.msg_id {
		case .Match_Phase:
			if m, mok := protocol.read_match_phase(&payload); mok {
				handle_match_phase(m)
			}
		case .Kill:
			if m, mok := protocol.read_kill(&payload); mok {
				log.infof("NET: kill {} -> {}", m.killer, m.victim)
			}
		}
		// a phase message may have torn the connection down (match end);
		// the rest of the datagram belongs to a connection that is gone
		if !net_client.active do return
	}

	// unreliable messages
	for !r.error && r.off < len(r.buf) {
		id := protocol.Msg_Id(protocol.read_u8(&r))
		#partial switch id {
		case .Snapshot:
			if s, sok := read_snapshot_msg(&r); sok {
				handle_snapshot(s)
			}
		case .Damage:
			if m, mok := protocol.read_damage(&r); mok {
				handle_damage(m)
			}
		case .Server_Disconnect:
			text := "SERVER CLOSED THE CONNECTION"
			if m, mok := protocol.read_disconnect(&r); mok {
				text = server_disconnect_text(m.reason)
			}
			net_fail(text)
			return
		case:
			return // unknown message, rest of the datagram unreadable
		}
	}
}

@(private = "file")
handle_match_phase :: proc(m: protocol.Match_Phase_Msg) {
	// Defensive: the server should never phase a practice slot, but another
	// match's phase must not pull the range into .Playing or .Match_End.
	if net_client.practice do return

	log.infof("NET: match phase {} (T {} : {} CT)", m.phase, m.t_score, m.ct_score)
	net_client.phase = m.phase
	net_client.t_score = int(m.t_score)
	net_client.ct_score = int(m.ct_score)

	#partial switch m.phase {
	case .Countdown, .Live:
		if scene.current == .Connecting {
			net_client.joined = true
			net_client.last_snapshot_time = time.tick_now()
			enter_scene(.Playing)
		}

	case .Post:
		// Post IS the match end: freeze the result, thank the server, leave.
		scene.final_t = int(m.t_score)
		scene.final_ct = int(m.ct_score)
		if scene.current == .Playing {
			log.infof("NET: match end T {} : {} CT", m.t_score, m.ct_score)
			net_disconnect()
			enter_scene(.Match_End)
		}
	}
}

// Reads one snapshot message and reconstructs it to a full snapshot against
// the baseline it names. Deltas carry that name inside the message, so it is
// peeked off a value copy of the reader first. A delta whose baseline the ring
// no longer holds must still be parsed -- unreliable messages carry no length
// prefix, so skipping it would lose the rest of the datagram -- but its result
// is discarded without advancing anything; our stale ack then ages out of the
// server's ring and the next full snapshot heals the stream.
@(private = "file")
read_snapshot_msg :: proc(r: ^protocol.Reader) -> (s: protocol.Snapshot, ok: bool) {
	peek := r^
	_ = protocol.read_u32(&peek) // server_tick
	baseline_tick := protocol.read_u32(&peek)
	if peek.error {
		r.error = true
		return
	}

	zero_base: protocol.Snapshot
	base := &zero_base
	baseline_held := true
	if baseline_tick != 0 {
		if held := snapshot_at(baseline_tick); held != nil {
			base = held
		} else {
			baseline_held = false
		}
	}

	start := r.off
	s, ok = protocol.read_snapshot(r, base)
	if !ok do return

	net_client.snap_bytes += r.off - start
	if baseline_tick == 0 {
		net_client.snap_full += 1
	} else {
		net_client.snap_delta += 1
	}

	if !baseline_held {
		log.warnf("NET: delta against evicted baseline {}, discarded", baseline_tick)
		return s, false
	}
	return s, true
}

@(private = "file")
handle_snapshot :: proc(s: protocol.Snapshot) {
	// On the range the snapshot is only proof of life: the sim is local, and
	// another match's phase, scores or entities must not leak into it.
	if net_client.practice {
		net_client.last_snapshot_time = time.tick_now()
		return
	}

	first := !net_client.have_snapshot
	slot := s.server_tick % SNAPSHOT_CAP
	net_client.snapshots[slot] = s
	net_client.valid[slot] = true
	if s.server_tick > net_client.latest_tick || first {
		net_client.latest_tick = s.server_tick
	}
	net_client.have_snapshot = true
	net_client.last_snapshot_time = time.tick_now()

	net_client.phase = s.phase
	net_client.time_left = s.time_left
	net_client.t_score = int(s.t_score)
	net_client.ct_score = int(s.ct_score)

	if first {
		log.infof("NET: first snapshot at tick {} ({} entities)", s.server_tick, card(s.present))
	}

	reconcile(&net_client.snapshots[slot])
}

@(private = "file")
handle_damage :: proc(m: protocol.Damage_Msg) {
	if m.tick > net_client.last_damage_tick {
		net_client.last_damage_tick = m.tick
	}
	rad := math.to_radians(m.direction)
	register_hit({math.cos(rad), math.sin(rad)}, int(m.amount))
	log.debugf("NET: damage {} from {:.0f} deg at tick {}", m.amount, m.direction, m.tick)
}

@(private = "file")
send_connect_request :: proc() {
	scratch: protocol.Connection
	protocol.connection_init(&scratch, 0)

	buf: [protocol.MTU]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&scratch, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Connect_Request))
	name := steam_persona()
	if name == "" do name = "PLAYER"
	request := protocol.Connect_Request {
		client_salt = net_client.client_salt,
		ticket_len  = u16(steam_state.ticket_len),
	}
	request.name_len = u8(copy(request.name[:], name))
	copy(request.ticket[:], steam_state.ticket[:steam_state.ticket_len])
	protocol.write_connect_request(&w, request)
	net_send(w.buf[:w.off])
}

@(private = "file")
send_keepalive :: proc() {
	buf: [256]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&net_client.conn, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Keepalive))
	net_send(w.buf[:w.off])
}

net_send :: proc(data: []u8) {
	net_client.last_send = time.tick_now()
	switch net_client.transport {
	case .Udp:
		if _, err := net.send_udp(net_client.socket, data, net_client.server_ep); err != nil {
			log.warnf("NET: send error {}", err)
		}
	case .Steam:
		steam_net_send(data)
	}
}

// Mirrors the buy choice to the server, which applies it on the next spawn --
// or immediately during the countdown. Reliable: a buy must not be lost.
net_send_loadout :: proc(l: game.Loadout) {
	if !net_client.got_accept do return
	if !protocol.queue_reliable_msg(
		&net_client.conn,
		.Loadout,
		protocol.write_loadout,
		protocol.Loadout_Msg{primary = l.primary, secondary = l.secondary, armor = l.armor},
	) {
		net_fail("PROTOCOL FAILURE")
		return
	}
	log.infof(
		"NET: loadout sent primary={} secondary={} armor={}",
		loadout_slot_name(l.primary),
		loadout_slot_name(l.secondary),
		l.armor,
	)
}

@(private = "file")
loadout_slot_name :: proc(index: i8) -> string {
	if index < 0 || int(index) >= game.WEAPON_COUNT do return "none"
	return game.WEAPONS[index].name
}

// Mirrors the local debug toggles to the server, which owns the simulation
// they are supposed to affect. Rides the reliable channel like every other
// control message; a no-op while not connected.
net_send_debug_flags :: proc() {
	if !net_client.got_accept do return
	protocol.queue_reliable_msg(
		&net_client.conn,
		.Debug_Flags,
		protocol.write_debug_flags,
		protocol.Debug_Flags{god = debug.god_mode, infinite_ammo = debug.infinite_ammo},
	)
}

// The snapshot stored for a given server tick, if the ring still holds it.
snapshot_at :: proc(tick: u32) -> ^protocol.Snapshot {
	slot := tick % SNAPSHOT_CAP
	if !net_client.valid[slot] do return nil
	if net_client.snapshots[slot].server_tick != tick do return nil
	return &net_client.snapshots[slot]
}
