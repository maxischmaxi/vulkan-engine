package main

import "../game"
import "../physics"
import "../protocol"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

// The dedicated server: no window, no Vulkan, no GLFW -- the same shared
// simulation the client predicts with, run authoritatively at 64 Hz against a
// UDP socket. Everything a client sends is treated as a claim about buttons,
// never about positions; that stance is the anti-cheat foundation, and it is
// cheaper to hold from day one than to retrofit.

Server :: struct {
	socket:  net.UDP_Socket,
	gs:      game.Game_State,
	tick:    u32,
	running: bool,
}

sv: Server

main :: proc() {
	context.logger = log.create_console_logger()

	port := protocol.DEFAULT_PORT
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-port="):
			value, ok := strconv.parse_int(arg[len("-port="):])
			if !ok || value <= 0 || value > 65535 {
				log.errorf("-port wants a port number, got {}", arg)
				os.exit(1)
			}
			port = value

		case arg == "-help" || arg == "--help":
			log.info("Options:\n  -port=N   listen on UDP port N (default 27015)")
			os.exit(0)

		case:
			log.warnf("Ignoring unknown option {}", arg)
		}
	}

	// The same map, the same bake, the same order as the client -- which is
	// what makes the two simulations bit-compatible.
	brushes := game.build_dust2()
	defer delete(brushes)
	sv.gs.collision = game.bake_collision(brushes)
	defer delete(sv.gs.collision)
	sv.gs.grid = physics.grid_build(sv.gs.collision)
	defer physics.grid_destroy(&sv.gs.grid)
	sv.gs.rng = rand.default_random_generator()

	socket, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		log.errorf("Cannot bind UDP port {}: {}", port, err)
		os.exit(1)
	}
	sv.socket = socket
	defer net.close(sv.socket)

	if block_err := net.set_blocking(sv.socket, false); block_err != nil {
		log.errorf("Cannot make the socket non-blocking: {}", block_err)
		os.exit(1)
	}

	init_match()

	log.infof(
		"Server: listening on UDP {}, {} Hz, map dust2 ({} colliders)",
		port,
		game.TICK_RATE,
		len(sv.gs.collision),
	)

	sv.running = true
	run_loop()
}
