package main

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:time"
import "game"
import "mm"
import "protocol"

// The client's side of the matchmaking queue: enter, heartbeat once a
// second, wait for a Match_Assign, hand the address to the normal connect
// path. Unlike the quickplay query there is NO give-up timer -- a queue
// takes as long as it takes, CANCEL is the way out. One automatic requeue
// covers the server dying between assignment and join.

Queue_Client :: struct {
	active:    bool,
	status:    mm.Queue_Status, // last master answer; drives the label
	got_reply: bool,
	socket:    net.UDP_Socket,
	master_ep: net.Endpoint,
	nonce:     u32,
	mode:      game.Mode,
	team_wish: game.Team, // rides the game Join; the master never sees it
	auto_join: bool, // handed to the connect the assignment launches
	queued:    u8, // "IN QUEUE 2 OF 5" from the last reply
	needed:    u8,
	last_send: time.Tick,
}

queue_client: Queue_Client

// Armed by an assignment: if the connect it launched fails, one silent
// requeue instead of the error screen. Disarmed by reaching the match or
// leaving the scene.
queue_launch: struct {
	armed:     bool,
	retried:   bool,
	mode:      game.Mode,
	wish:      game.Team,
	auto_join: bool,
}

queue_start :: proc(mode: game.Mode, team_wish: game.Team, auto_join := true) {
	queue_stop()

	ep, ok := net.parse_endpoint(cli.master)
	if !ok {
		resolved, err := net.resolve_ip4(cli.master)
		if err != nil {
			log.errorf("QUEUE: cannot resolve {}: {}", cli.master, err)
			queue_fail("BAD MASTER ADDRESS")
			return
		}
		ep = resolved
	}
	if ep.port == 0 do ep.port = mm.MM_DEFAULT_PORT

	socket, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("QUEUE: cannot open a socket: {}", err)
		queue_fail("CANNOT OPEN A SOCKET")
		return
	}
	if berr := net.set_blocking(socket, false); berr != nil {
		net.close(socket)
		queue_fail("CANNOT OPEN A SOCKET")
		return
	}

	queue_client.active = true
	queue_client.socket = socket
	queue_client.master_ep = ep
	queue_client.nonce = rand.uint32()
	queue_client.mode = mode
	queue_client.team_wish = team_wish
	queue_client.auto_join = auto_join

	log.infof("QUEUE: entered {} queue at {}", mode, net.to_string(ep))
	queue_send_enter()
}

// Called every frame next to master_query_pump.
queue_pump :: proc() {
	if !queue_client.active do return

	if time.duration_seconds(time.tick_since(queue_client.last_send)) > mm.QUEUE_RESEND_SECONDS {
		queue_send_enter()
	}

	buf: [mm.MM_MAX_DATAGRAM]u8
	for {
		n, ep, err := net.recv_udp(queue_client.socket, buf[:])
		if err == .Would_Block do break
		if err != nil {
			log.warnf("QUEUE: recv error {}", err)
			break
		}
		if ep != queue_client.master_ep do continue
		r, msg, ok := mm.frame_open(buf[:n])
		if !ok do continue

		#partial switch msg {
		case .Queue_Reply:
			m, mok := mm.read_queue_reply(&r)
			if !mok || m.nonce != queue_client.nonce do continue
			if m.status == .Bad_Version {
				log.warn("QUEUE: version mismatch with the master")
				queue_fail("VERSION MISMATCH WITH MASTER")
				return
			}
			if m.status != queue_client.status && queue_client.got_reply {
				log.infof("QUEUE: status {}", m.status)
			}
			queue_client.status = m.status
			queue_client.queued = m.queued
			queue_client.needed = m.needed
			queue_client.got_reply = true

		case .Match_Assign:
			m, mok := mm.read_match_assign(&r)
			if !mok || m.nonce != queue_client.nonce do continue
			mode := queue_client.mode
			wish := queue_client.team_wish
			auto_join := queue_client.auto_join
			addr := m.addr
			log.infof("QUEUE: assigned match {}", m.match_id)
			queue_stop_silent()
			queue_launch = {
				armed     = true,
				mode      = mode,
				wish      = wish,
				auto_join = auto_join,
			}
			switch addr.kind {
			case .Steam:
				log.infof("QUEUE: server steamid {}", addr.steam_id)
				net_connect_start_steam(addr.steam_id, wish, auto_join)
			case .Udp:
				server_ep := net.Endpoint {
					address = net.IP4_Address(addr.ip4),
					port    = int(addr.port),
				}
				log.infof("QUEUE: server {}", net.to_string(server_ep))
				net_connect_start_ep(server_ep, wish, auto_join)
			}
			return
		}
	}
}

// The courtesy leave: three best-effort datagrams, then the socket dies.
// Safe in any state; enter_scene(.Menu) runs it like master_query_stop.
queue_stop :: proc() {
	if !queue_client.active do return
	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Queue_Leave)
	mm.write_queue_leave(&w, {nonce = queue_client.nonce})
	for _ in 0 ..< 3 {
		if _, err := net.send_udp(queue_client.socket, buf[:w.off], queue_client.master_ep);
		   err != nil {
			break
		}
	}
	queue_stop_silent()
}

// Closing without the leave: the assignment path, where the entry must
// linger at the master as the held seat.
@(private = "file")
queue_stop_silent :: proc() {
	if !queue_client.active do return
	net.close(queue_client.socket)
	queue_client = {}
}

// One silent requeue after a failed connect that the queue launched. True
// when the failure is handled and the caller must not fall through to the
// error screen.
queue_relaunch :: proc() -> bool {
	if !queue_launch.armed || queue_launch.retried do return false
	if scene.current != .Connecting && scene.current != .Team_Select do return false
	queue_launch.retried = true
	log.warn("QUEUE: connect failed, re-entering the queue")
	queue_start(queue_launch.mode, queue_launch.wish, queue_launch.auto_join)
	return true
}

queue_launch_disarm :: proc() {
	queue_launch = {}
}

// What the .Connecting screen shows while queued. Glyph-safe uppercase.
queue_label :: proc() -> string {
	#partial switch queue_client.status {
	case .Spawning:
		return "STARTING SERVER"
	case .No_Capacity:
		return "WAITING FOR CAPACITY"
	}
	if queue_client.got_reply && queue_client.needed > 1 {
		return fmt.tprintf("IN QUEUE {} OF {}", queue_client.queued, queue_client.needed)
	}
	return "IN QUEUE"
}

@(private = "file")
queue_send_enter :: proc() {
	accepts: u8
	when STEAM_REQUIRED {
		accepts = mm.ACCEPT_STEAM
	} else {
		accepts = mm.ACCEPT_UDP
		if steam_available() do accepts |= mm.ACCEPT_STEAM
	}

	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Queue_Enter)
	mm.write_queue_enter(
		&w,
		{
			nonce = queue_client.nonce,
			region = mm.region_from_string(cli.region),
			game_version = protocol.PROTOCOL_VERSION,
			accepts = accepts,
			mode = queue_client.mode,
		},
	)
	if _, err := net.send_udp(queue_client.socket, buf[:w.off], queue_client.master_ep);
	   err != nil {
		log.warnf("QUEUE: send error {}", err)
	}
	queue_client.last_send = time.tick_now()
}

@(private = "file")
queue_fail :: proc(text: string) {
	queue_stop_silent()
	scene.error_text = text
	enter_scene(.Menu)
}
