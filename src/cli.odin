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
	// Sit in the team select for this many seconds before the --join team is
	// picked. The browse path's E2E hook: the connection is up, the roster
	// streams in, and nothing joins until the timer runs out.
	join_delay:    int,
	// Skip the menu and enter the practice range. Same development role as
	// --join; when both are given, practice wins.
	practice:      bool,
	// Start holding this weapon by name. The only way to look at a viewmodel
	// without a keyboard, which is what makes a screenshot of one repeatable.
	weapon:        string,
	// Start scoped, for the same reason: the scope is a right click, and what it
	// does to the lens is exactly what a screenshot has to be able to catch.
	// Ignored by a weapon without a scope.
	zoom:          bool,
	// Skip Steam init entirely. Dev builds also fall back on their own when
	// Steam is not running; the flag exists to test that path deliberately.
	no_steam:      bool,
	// Join a server over Steam by its SteamID64 (printed by the server when it
	// logs on). Zero means the loopback UDP dev server.
	connect_id:    u64,
	// Ask this master for a server instead of naming one. --connect wins when
	// both are given.
	master:        string,
	// Region preference for the master query; empty takes any region.
	region:        string,
	// Dev builds only: fire one deliberately illegal message after the accept,
	// so the server's anti-cheat pipeline is testable headless. "debugmsg" is
	// the only probe today; the seam future probes extend.
	cheat_probe:   string,
	// Force a competitive HUD state with synthetic data on the practice range,
	// so every element can be screenshot without a server. See hud_preview.odin
	// for the accepted views.
	hudpreview:    string,
	// Headless economy probe: send a buy for this weapon at every comp freeze,
	// so the server's price gate is testable from logs alone.
	auto_buy:      string,
	// Skip the menu and enter the matchmaking queue: "tdm" or "comp".
	// Needs --master; the headless twin of the menu's play flow.
	queue:         string,
	// Log every audio event. The headless E2E's ears: a machine with no sound
	// device still shows which sounds would have played.
	audio_log:     bool,
	// Log the camera's z pipeline every frame: raw interpolated feet, smoothed
	// feet, final eye. The eye smoothing's E2E trace, read the same way.
	view_log:      bool,
	// Log which pawn ids each snapshot carries. Fog of war's E2E eye: an enemy
	// the server decided you cannot see simply stops appearing in this list,
	// which is testable from a log and needs neither a screen nor a keyboard.
	fow_log:       bool,
	// Log the belt and what is in the hands, whenever either changes. The scroll
	// wheel and the number keys are exactly what a headless test cannot press,
	// so this is the ear on the other half of that: it shows the server's
	// counts arriving and the hand agreeing with them.
	hand_log:      bool,
	// Buy this grenade and keep throwing it: "he", "flash", "smoke",
	// "molotov". The throw path's E2E hook, the way --auto-buy is the
	// economy's -- a grenade is a mouse button, and mouse buttons are exactly
	// what a headless test cannot press.
	nade:          string,
}

cli: Cli

CLI_USAGE :: `Options:
  --gpu=N       render on device N from the list printed at startup
  --gpu-timing  measure each pass on the GPU and show it in the overlay
  --bench=N     run the fixed camera path for N frames, print one line, exit
  --join=TEAM   skip the menu and join the local server as t or ct
  --join-delay=S  browse the team select for S seconds before joining (E2E)
  --queue=MODE  skip the menu and queue for tdm or comp (needs --master)
  --connect=ID  join the server with this steamid64 over Steam
  --master=H:P  ask the master at H:P for a server to join
  --region=STR  region preference for the master query
  --practice    skip the menu and enter the practice range
  --weapon=NAME start holding a weapon by name, e.g. ak, glock, awp, knife
  --zoom        start scoped, if the weapon has a scope
  --hudpreview=V  forced HUD/menu state: topbar, warmup, freeze, roundend, bomb,
                  outro, menu, modeselect[-hoverl|-hoverr], teamselect[-hoverl|-hoverr]
  --auto-buy=NAME send a buy for this weapon at every comp freeze (economy E2E)
  --no-steam    run without Steam, dev builds only
  --cheat-probe=K  dev builds only: send illegal message K after connect (debugmsg)
  --no-light-cull  shade every light in every tile, to measure the culling
  --no-depth-prepass  shade the world without the depth-only first pass
  --audio-log   log every audio event, for headless testing without speakers
  --view-log    log the camera height pipeline every frame
  --fow-log     log which pawn ids each snapshot carries (fog of war)
  --hand-log    log the grenade belt and what is in the hands, on every change
  --nade=KIND   buy and repeatedly throw a grenade: he, flash, smoke, molotov
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

		case strings.has_prefix(arg, "--master="):
			cli.master = arg[len("--master="):]
			if cli.master == "" {
				log.errorf("--master wants HOST:PORT, got {}", arg)
			}

		case strings.has_prefix(arg, "--region="):
			cli.region = arg[len("--region="):]

		case strings.has_prefix(arg, "--join="):
			value := arg[len("--join="):]
			if value != "t" && value != "ct" {
				log.errorf("--join wants t or ct, got {}", arg)
				continue
			}
			cli.join = value

		case strings.has_prefix(arg, "--join-delay="):
			value, ok := strconv.parse_int(arg[len("--join-delay="):])
			if !ok || value <= 0 {
				log.errorf("--join-delay wants a positive number, got {}", arg)
				continue
			}
			cli.join_delay = value

		case strings.has_prefix(arg, "--queue="):
			value := arg[len("--queue="):]
			if value != "tdm" && value != "comp" {
				log.errorf("--queue wants tdm or comp, got {}", arg)
				continue
			}
			cli.queue = value

		case arg == "--practice":
			cli.practice = true

		case arg == "--audio-log":
			cli.audio_log = true

		case arg == "--view-log":
			cli.view_log = true

		case arg == "--fow-log":
			cli.fow_log = true

		case arg == "--hand-log":
			cli.hand_log = true

		case strings.has_prefix(arg, "--nade="):
			cli.nade = arg[len("--nade="):]

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

		case arg == "--zoom":
			cli.zoom = true

		case strings.has_prefix(arg, "--hudpreview="):
			cli.hudpreview = arg[len("--hudpreview="):]

		case strings.has_prefix(arg, "--auto-buy="):
			cli.auto_buy = arg[len("--auto-buy="):]

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
	if cli.queue != "" && cli.join != "" {
		log.warn("--queue wins over --join")
		cli.join = ""
	}
	if cli.queue != "" && cli.master == "" {
		log.error("--queue needs --master")
		os.exit(1)
	}
	if cli.join_delay > 0 && cli.join == "" {
		log.error("--join-delay needs --join")
		os.exit(1)
	}
}
