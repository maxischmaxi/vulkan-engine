package main

import "../mm"
import "core:log"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// The master: the one process that knows which game servers exist, how full
// they are, and which fleet agents could spawn more. Everything it knows is
// soft state rebuilt from 2-second heartbeats -- kill it, restart it, and the
// registry repopulates within a heartbeat interval. That is why there is no
// database and no Redis behind it.
//
// One UDP socket, one thread: drain the socket, dispatch, sweep, sleep.

Master :: struct {
	socket:     net.UDP_Socket,
	token:      mm.Token,
	idle_stop:  f64, // seconds an empty spawned server may idle before draining
	floor:      int, // joinable servers to keep per region with an agent
	last_sweep: time.Tick,
	running:    bool,
}

ms: Master

// The sweep (expiry, floors, drains) runs at this cadence, not per loop turn.
SWEEP_SECONDS :: 1.0

main :: proc() {
	context.logger = log.create_console_logger()

	port := mm.MM_DEFAULT_PORT
	ms.idle_stop = 300
	ms.floor = 1
	have_token := false

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-port="):
			value, ok := strconv.parse_int(arg[len("-port="):])
			if !ok || value <= 0 || value > 65535 {
				log.errorf("-port wants a port number, got {}", arg)
				os.exit(1)
			}
			port = value

		case strings.has_prefix(arg, "-token="):
			ms.token = mm.token_from_string(arg[len("-token="):])
			have_token = true

		case strings.has_prefix(arg, "-idle-stop="):
			value, ok := strconv.parse_int(arg[len("-idle-stop="):])
			if !ok || value < 0 {
				log.errorf("-idle-stop wants seconds, got {}", arg)
				os.exit(1)
			}
			ms.idle_stop = f64(value)

		case strings.has_prefix(arg, "-floor="):
			value, ok := strconv.parse_int(arg[len("-floor="):])
			if !ok || value < 0 {
				log.errorf("-floor wants a count, got {}", arg)
				os.exit(1)
			}
			ms.floor = value

		case arg == "-help" || arg == "--help":
			log.info(
				"Options:\n" +
				"  -port=N       listen on UDP port N (default 27050)\n" +
				"  -token=STR    shared secret for server/agent traffic (required)\n" +
				"  -idle-stop=S  drain spawned servers empty for S seconds (default 300)\n" +
				"  -floor=N      joinable servers to keep per agent region (default 1)",
			)
			os.exit(0)

		case:
			log.warnf("Ignoring unknown option {}", arg)
		}
	}

	if !have_token {
		log.error("-token is required; servers and agents must present the same one")
		os.exit(1)
	}

	socket, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		log.errorf("Cannot bind UDP port {}: {}", port, err)
		os.exit(1)
	}
	ms.socket = socket
	if berr := net.set_blocking(ms.socket, false); berr != nil {
		log.errorf("Cannot make the socket non-blocking: {}", berr)
		os.exit(1)
	}

	log.infof("Master: listening on {}", port)

	buf: [mm.MM_MAX_DATAGRAM]u8
	ms.running = true
	for ms.running {
		for {
			n, ep, rerr := net.recv_udp(ms.socket, buf[:])
			if rerr == .Would_Block do break
			if rerr != nil {
				log.warnf("Master: recv error {}", rerr)
				break
			}
			dispatch(ep, buf[:n])
		}

		if time.duration_seconds(time.tick_since(ms.last_sweep)) >= SWEEP_SECONDS {
			ms.last_sweep = time.tick_now()
			registry_sweep()
			scale_sweep()
		}

		time.sleep(10 * time.Millisecond)
	}
}

master_send :: proc(ep: net.Endpoint, data: []u8) {
	if _, err := net.send_udp(ms.socket, data, ep); err != nil {
		log.warnf("Master: send error {}", err)
	}
}
