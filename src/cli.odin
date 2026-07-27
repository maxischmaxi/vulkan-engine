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
	gpu_index:  int, // -1 picks the best device
	gpu_timing: bool,
	bench:      int, // frames to measure, 0 means play normally
}

cli: Cli

CLI_USAGE :: `Options:
  --gpu=N       render on device N from the list printed at startup
  --gpu-timing  measure each pass on the GPU and show it in the overlay
  --bench=N     run the fixed camera path for N frames, print one line, exit
  --help        print this`

parse_cli :: proc() {
	cli.gpu_index = -1

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
