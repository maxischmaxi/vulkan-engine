package main

import "core:log"
import "core:math/rand"
import "core:net"
import "core:time"
import "game"
import "mm"
import "protocol"

// The client's conversation with the master: one Find_Server question, resent
// every second until the answer is a server to join. "Spawning" means an
// instance is booting somewhere -- keep asking, the fresh server's first
// heartbeat flips the answer to Ok. The whole exchange is stateless datagrams;
// cancelling is closing the socket.

Master_Query :: struct {
	active:    bool,
	spawning:  bool, // the label switch: FINDING vs STARTING
	socket:    net.UDP_Socket,
	master_ep: net.Endpoint,
	nonce:     u32,
	team:      game.Team,
	started:   time.Tick,
	last_send: time.Tick,
}

master_query: Master_Query

master_query_start :: proc(team: game.Team) {
	master_query_stop()

	ep, ok := net.parse_endpoint(cli.master)
	if !ok {
		resolved, err := net.resolve_ip4(cli.master)
		if err != nil {
			log.errorf("MASTER: cannot resolve {}: {}", cli.master, err)
			master_query_fail("BAD MASTER ADDRESS")
			return
		}
		ep = resolved
	}
	if ep.port == 0 do ep.port = mm.MM_DEFAULT_PORT

	socket, err := net.make_bound_udp_socket(net.IP4_Any, 0)
	if err != nil {
		log.errorf("MASTER: cannot open a socket: {}", err)
		master_query_fail("CANNOT OPEN A SOCKET")
		return
	}
	if berr := net.set_blocking(socket, false); berr != nil {
		net.close(socket)
		master_query_fail("CANNOT OPEN A SOCKET")
		return
	}

	master_query.active = true
	master_query.socket = socket
	master_query.master_ep = ep
	master_query.nonce = rand.uint32()
	master_query.team = team
	master_query.started = time.tick_now()

	log.infof("MASTER: finding server at {}", net.to_string(ep))
	master_query_send()
}

// Called every frame next to net_client_pump.
master_query_pump :: proc() {
	if !master_query.active do return

	if time.duration_seconds(time.tick_since(master_query.started)) > mm.CLIENT_GIVEUP_SECONDS {
		log.warn("MASTER: no server within the budget")
		master_query_fail("NO SERVER FOUND")
		return
	}
	if time.duration_seconds(time.tick_since(master_query.last_send)) > mm.CLIENT_RETRY_SECONDS {
		master_query_send()
	}

	buf: [mm.MM_MAX_DATAGRAM]u8
	for {
		n, ep, err := net.recv_udp(master_query.socket, buf[:])
		if err == .Would_Block do break
		if err != nil {
			log.warnf("MASTER: recv error {}", err)
			break
		}
		// Only the master we asked, only the question we asked.
		if ep != master_query.master_ep do continue
		r, msg, ok := mm.frame_open(buf[:n])
		if !ok || msg != .Find_Response do continue
		resp, rok := mm.read_find_response(&r)
		if !rok || resp.nonce != master_query.nonce do continue

		switch resp.status {
		case .Ok:
			team := master_query.team
			addr := resp.addr
			master_query_stop()
			switch addr.kind {
			case .Steam:
				log.infof("MASTER: got server steamid {}", addr.steam_id)
				net_connect_start_steam(addr.steam_id, team)
			case .Udp:
				server_ep := net.Endpoint {
					address = net.IP4_Address(addr.ip4),
					port    = int(addr.port),
				}
				log.infof("MASTER: got server {}", net.to_string(server_ep))
				net_connect_start_ep(server_ep, team)
			}
			return

		case .Spawning:
			if !master_query.spawning {
				master_query.spawning = true
				log.info("MASTER: a server is starting for us")
			}

		case .No_Capacity:
			log.warn("MASTER: no capacity")
			master_query_fail("NO SERVERS AVAILABLE")
			return
		}
	}
}

// Safe to call in any state; enter_scene(.Menu) runs it so ESC and CANCEL in
// .Connecting tear the query down like they tear the connection down.
master_query_stop :: proc() {
	if !master_query.active do return
	net.close(master_query.socket)
	master_query = {}
}

// What the .Connecting screen shows. Glyph-safe: uppercase, no ? & ' @.
connecting_label :: proc() -> string {
	if queue_client.active do return queue_label()
	if master_query.active {
		return master_query.spawning ? "STARTING SERVER" : "FINDING SERVER"
	}
	return "CONNECTING TO SERVER"
}

@(private = "file")
master_query_send :: proc() {
	accepts: u8
	when STEAM_REQUIRED {
		accepts = mm.ACCEPT_STEAM
	} else {
		accepts = mm.ACCEPT_UDP
		if steam_available() do accepts |= mm.ACCEPT_STEAM
	}

	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Find_Server)
	mm.write_find_server(
		&w,
		{
			nonce = master_query.nonce,
			region = mm.region_from_string(cli.region),
			game_version = protocol.PROTOCOL_VERSION,
			accepts = accepts,
			mode = .TDM, // quickplay is TDM; comp goes through the queue
		},
	)
	if _, err := net.send_udp(master_query.socket, buf[:w.off], master_query.master_ep);
	   err != nil {
		log.warnf("MASTER: send error {}", err)
	}
	master_query.last_send = time.tick_now()
}

@(private = "file")
master_query_fail :: proc(text: string) {
	master_query_stop()
	scene.error_text = text
	enter_scene(.Menu)
}
