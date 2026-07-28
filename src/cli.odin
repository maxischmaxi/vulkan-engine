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
	// Start holding this weapon by name. The only way to look at a viewmodel
	// without a keyboard, which is what makes a screenshot of one repeatable.
	weapon:        string,
}

cli: Cli

CLI_USAGE :: `Options:
  --gpu=N       render on device N from the list printed at startup
  --gpu-timing  measure each pass on the GPU and show it in the overlay
  --bench=N     run the fixed camera path for N frames, print one line, exit
  --join=TEAM   skip the menu and join the local server as t or ct
  --weapon=NAME start holding a weapon by name, e.g. rifle, pistol, knife
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

		case strings.has_prefix(arg, "--join="):
			value := arg[len("--join="):]
			if value != "t" && value != "ct" {
				log.errorf("--join wants t or ct, got {}", arg)
				continue
			}
			cli.join = value

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
}
