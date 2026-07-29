package main

import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

// Options that have to be known before anything exists. The device index is
// chosen before the instance has a surface to test against, so it cannot come
// from a config file the renderer loads later, and it is the switch that turns
// a two-GPU development machine into a low-end test rig.

Cli :: struct {
	gpu_index:     int, // -1 picks the best device
	gpu_timing:    bool,
	bench:         int, // frames to measure, 0 means play normally
	no_light_cull: bool, // every-light masks: the culled path's A/B control
	// Depth-only world pass before shading, on by default: measured 0.4 ms
	// faster at High on the RADV iGPU and neutral everywhere else. The off
	// switch exists because the sign of a prepass is content-dependent.
	depth_prepass: bool,
	// Skip the menu and join a match immediately: "t" or "ct". Development
	// convenience and the only way to drive a match without clicking.
	join:          string,
	// Skip the menu and enter the practice range. Same development role as
	// --join; when both are given, practice wins.
	practice:      bool,
	// Start holding this weapon by name. The only way to look at a viewmodel
	// without a keyboard, which is what makes a screenshot of one repeatable.
	weapon:        string,
	// Skip Steam init entirely. Dev builds also fall back on their own when
	// Steam is not running; the flag exists to test that path deliberately.
	no_steam:      bool,
	// Join a server over Steam by its SteamID64 (printed by the server when it
	// logs on). Zero means the loopback UDP dev server.
	connect_id:    u64,
	// Dev builds only: fire one deliberately illegal message after the accept,
	// so the server's anti-cheat pipeline is testable headless. "debugmsg" is
	// the only probe today; the seam future probes extend.
	cheat_probe:   string,
}

cli: Cli

CLI_USAGE :: `Options:
  --gpu=N       render on device N from the list printed at startup
  --gpu-timing  measure each pass on the GPU and show it in the overlay
  --bench=N     run the fixed camera path for N frames, print one line, exit
  --join=TEAM   skip the menu and join the local server as t or ct
  --connect=ID  join the server with this steamid64 over Steam
  --practice    skip the menu and enter the practice range
  --weapon=NAME start holding a weapon by name, e.g. ak, glock, awp, knife
  --no-steam    run without Steam, dev builds only
  --cheat-probe=K  dev builds only: send illegal message K after connect (debugmsg)
  --no-light-cull  shade every light in every tile, to measure the culling
  --no-depth-prepass  shade the world without the depth-only first pass
  --help        print this`

parse_cli :: proc() {
	cli.gpu_index = -1
	cli.depth_prepass = true

	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--gpu="):
			value, ok := strconv.parse_int(arg[len("--gpu="):])
			if !ok {
				log.errorf("--gpu wants a number, got {}", arg)
				continue
			}
			cli.gpu_index = value

		case arg == "--gpu-timing":
			cli.gpu_timing = true

		case arg == "--no-light-cull":
			cli.no_light_cull = true

		case arg == "--no-depth-prepass":
			cli.depth_prepass = false

		case strings.has_prefix(arg, "--connect="):
			value, ok := strconv.parse_u64(arg[len("--connect="):])
			if !ok || value == 0 {
				log.errorf("--connect wants a steamid64, got {}", arg)
				continue
			}
			cli.connect_id = value

		case strings.has_prefix(arg, "--join="):
			value := arg[len("--join="):]
			if value != "t" && value != "ct" {
				log.errorf("--join wants t or ct, got {}", arg)
				continue
			}
			cli.join = value

		case arg == "--practice":
			cli.practice = true

		case arg == "--no-steam":
			when STEAM_REQUIRED {
				log.error("--no-steam is not available in this build")
				os.exit(1)
			} else {
				cli.no_steam = true
			}

		case strings.has_prefix(arg, "--cheat-probe="):
			when STEAM_REQUIRED {
				log.error("--cheat-probe is not available in this build")
				os.exit(1)
			} else {
				cli.cheat_probe = arg[len("--cheat-probe="):]
			}

		case strings.has_prefix(arg, "--weapon="):
			cli.weapon = arg[len("--weapon="):]

		case strings.has_prefix(arg, "--bench="):
			value, ok := strconv.parse_int(arg[len("--bench="):])
			if !ok || value <= 0 {
				log.errorf("--bench wants a positive number, got {}", arg)
				continue
			}
			cli.bench = value

		case arg == "--help", arg == "-h":
			log.info(CLI_USAGE)
			os.exit(0)

		case:
			log.warnf("Ignoring unknown option {}", arg)
		}
	}

	if cli.practice && cli.join != "" {
		log.warn("--practice wins over --join")
		cli.join = ""
	}
}
