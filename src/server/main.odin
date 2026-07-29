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
	socket:   net.UDP_Socket,
	gs:       game.Game_State,
	tick:     u32,
	running:  bool,
	// Pure-UDP mode: skip Steam entirely. Dev only; STEAM_REQUIRED builds
	// refuse the flag.
	insecure: bool,
}

sv: Server

main :: proc() {
	context.logger = log.create_console_logger()

	port := protocol.DEFAULT_PORT
	ban_path := BAN_FILE_DEFAULT
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-port="):
			value, ok := strconv.parse_int(arg[len("-port="):])
			if !ok || value <= 0 || value > 65535 {
				log.errorf("-port wants a port number, got {}", arg)
				os.exit(1)
			}
			port = value

		case arg == "-insecure":
			when STEAM_REQUIRED {
				log.error("-insecure is not available in this build")
				os.exit(1)
			} else {
				sv.insecure = true
			}

		case strings.has_prefix(arg, "-banlist="):
			ban_path = arg[len("-banlist="):]
			if ban_path == "" {
				log.errorf("-banlist wants a file path, got {}", arg)
				os.exit(1)
			}

		case arg == "-ac-shadow":
			ac.shadow = true

		case arg == "-harden":
			when STEAM_REQUIRED {
				log.info("-harden is implied in this build")
			} else {
				ac.harden = true
			}

		case arg == "-help" || arg == "--help":
			log.info(
				"Options:\n" +
				"  -port=N     listen on UDP port N (default 27015)\n" +
				"  -insecure   UDP only, no Steam (dev builds)\n" +
				"  -banlist=F  ban list file (default bans.txt)\n" +
				"  -ac-shadow  statistical detectors log instead of banning\n" +
				"  -harden     refuse dev affordances like a release server (dev builds)",
			)
			os.exit(0)

		case:
			log.warnf("Ignoring unknown option {}", arg)
		}
	}

	ban_list_load(ban_path)

	// The same map, the same bake, the same order as the client -- which is
	// what makes the two simulations bit-compatible.
	brushes := game.build_dust2()
	defer delete(brushes)
	sv.gs.collision = game.bake_collision(brushes)
	defer delete(sv.gs.collision)
	sv.gs.grid = physics.grid_build(sv.gs.collision)
	defer physics.grid_destroy(&sv.gs.grid)
	sv.gs.rng = rand.default_random_generator()

	when !STEAM_REQUIRED {
		if !udp_open(port) do os.exit(1)
		defer udp_close()
	}

	steam_server_init(port)
	defer steam_server_shutdown()

	init_match()

	log.infof(
		"Server: up at {} Hz, map dust2 ({} colliders)",
		game.TICK_RATE,
		len(sv.gs.collision),
	)

	sv.running = true
	run_loop()
}
