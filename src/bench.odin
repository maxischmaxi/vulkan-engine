package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "game"
import "vendor:glfw"
import vk "vendor:vulkan"

// A fixed camera path, a fixed clock and a fixed firing schedule, so two runs of
// the same build produce the same numbers and two builds can be compared.
//
// Nothing here is a game mode. It exists because three items on the optimisation
// list have genuinely unknown sign, and "it feels smoother" cannot decide them.
//
// Two things it deliberately does that a casual fps counter does not:
//   - it reports percentiles, because a stutter is what a player notices and an
//     average is exactly the statistic that hides one;
//   - it spends a stretch of the run firing, because the point of any future
//     light culling is the moment the screen is full of muzzle flashes, and an
//     average over a quiet map would report that work as worthless.

// Long enough for clocks to settle and the texture cache to warm, short enough
// that a 1200-frame run is still mostly measurement.
@(private = "file")
BENCH_WARMUP :: 120

// Fixed rather than taken from the clock: one tick per frame makes the
// simulation depend on the frame index alone, so the same frame number always
// sees the same world.
@(private = "file")
BENCH_DT :: game.TICK_DT

@(private = "file")
BENCH_SEED :: u64(0x64757374)

// Where the tour goes, as indices into game.MAP_SPAWN_AREAS. Reading that list rather
// than holding coordinates means the path cannot point at a room the map no
// longer has -- the same reason debug_teleport reads it.
//
// The order alternates open ground against roofed corridor: the two stress
// opposite things, and a single average over only one of them describes nothing.
@(private = "file")
BENCH_ROUTE := []int{0, 5, 6, 7, 8, 4, 3, 2, 1, 9, 10, 11, 12, 13}

// How long the camera takes to walk from one room to the next, and how long it
// pauses to look around once there.
@(private = "file")
BENCH_TRAVEL_FRAMES :: 60

@(private = "file")
BENCH_DWELL_FRAMES :: 20

Bench :: struct {
	active: bool,
	frame:  int,
	total:  int,
	last:   f64, // wall clock at the previous frame's start
	times:  [dynamic]f32, // per measured frame, milliseconds
	gpu:    [Gpu_Zone]f64, // summed over measured frames
}

bench: Bench

bench_active :: proc() -> bool {
	return bench.active
}

init_bench :: proc() {
	if cli.bench == 0 do return

	bench.active = true
	bench.total = cli.bench + BENCH_WARMUP
	bench.times = make([dynamic]f32, 0, cli.bench)

	// The bot AI is the only other source of randomness in a frame, and its
	// default generator is seeded per process. Pinning it here is what makes two
	// runs comparable rather than merely similar.
	rand.reset(BENCH_SEED, bot_rng)

	// The path teleports every frame, so collision would fight it the whole way.
	player.noclip = true

	log.infof("Bench: {} frames after {} warmup, seed {}", cli.bench, BENCH_WARMUP, BENCH_SEED)
}

destroy_bench :: proc() {
	delete(bench.times)
}

// Where the camera is on frame `f`, and which way it looks.
@(private = "file")
bench_pose :: proc(f: int) -> (position: [3]f32, yaw: f32) {
	leg := BENCH_TRAVEL_FRAMES + BENCH_DWELL_FRAMES
	step := (f / leg) % len(BENCH_ROUTE)
	into := f % leg

	from := room_center(BENCH_ROUTE[step])
	to := room_center(BENCH_ROUTE[(step + 1) % len(BENCH_ROUTE)])

	t := f32(min(into, BENCH_TRAVEL_FRAMES)) / f32(BENCH_TRAVEL_FRAMES)
	position = from + (to - from) * t

	// Facing where it is going while travelling, then sweeping the room while
	// standing in it -- a still camera in a corner measures one wall.
	heading := math.to_degrees(math.atan2(to.y - from.y, to.x - from.x))
	if into <= BENCH_TRAVEL_FRAMES do return position, heading

	sweep := f32(into - BENCH_TRAVEL_FRAMES) / f32(BENCH_DWELL_FRAMES)
	return position, heading + sweep * 360
}

@(private = "file")
room_center :: proc(index: int) -> [3]f32 {
	area := game.MAP_SPAWN_AREAS[index]
	return {(area.min.x + area.max.x) * 0.5, (area.min.y + area.max.y) * 0.5, area.floor + 1.0}
}

// The second half of every dwell is spent firing, so a good share of the run
// carries the transient lights that the light loop is expensive for.
bench_fire_held :: proc() -> bool {
	if !bench.active do return false

	leg := BENCH_TRAVEL_FRAMES + BENCH_DWELL_FRAMES
	into := bench.frame % leg
	return into > BENCH_TRAVEL_FRAMES + BENCH_DWELL_FRAMES / 2
}

// Replaces the clock and the input for one frame, and banks how long the
// previous one took. Returns how many simulation steps to run, always one.
//
// The measurement is taken here, at the top of a frame, rather than where the
// simulation ends: the gap between two frame starts is the only span that
// contains all of a frame, drawing and presenting included.
bench_step :: proc() -> int {
	now := glfw.GetTime()
	elapsed := f32(now - bench.last) * 1000
	bench.last = now

	bench.frame += 1
	if bench.frame > BENCH_WARMUP + 1 {
		append(&bench.times, elapsed)
		for zone in Gpu_Zone do bench.gpu[zone] += f64(gpu_timer.ms[zone])
	}
	if bench.frame > bench.total do bench_report()

	// The simulation runs off the frame index, not off how long any of this took.
	game.clock.frame_dt = BENCH_DT
	game.clock.alpha = 0
	game.clock.tick_count += 1

	position, yaw := bench_pose(bench.frame)
	teleport_player(position)
	camera.yaw = yaw
	camera.pitch = 0

	return 1
}

@(private = "file")
percentile :: proc(sorted: []f32, p: f32) -> f32 {
	if len(sorted) == 0 do return 0
	i := int(p * f32(len(sorted) - 1) + 0.5)
	return sorted[clamp(i, 0, len(sorted) - 1)]
}

// One machine-readable line, so a set of runs sorts and diffs.
//
// Run it three times and take the median. On an integrated GPU the run-to-run
// spread from clock and thermal behaviour is 10-20 %, which is wider than most
// of the individual wins anyone would be trying to measure -- a single
// before/after pair is not evidence, and treating it as one is how a change that
// makes things worse gets believed.
bench_report :: proc() {
	slice.sort(bench.times[:])

	sum: f64
	for t in bench.times do sum += f64(t)
	n := max(len(bench.times), 1)

	b := fmt.tprintf(
		"BENCH frames=%d avg=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f",
		len(bench.times),
		sum / f64(n),
		percentile(bench.times[:], 0.50),
		percentile(bench.times[:], 0.95),
		percentile(bench.times[:], 0.99),
		percentile(bench.times[:], 0.99999),
	)

	gpu := ""
	if gpu_timer.enabled {
		gpu = fmt.tprintf(
			" shadow=%.2f world=%.2f props=%.2f decals=%.2f viewmodel=%.2f hud=%.2f",
			bench.gpu[.Shadow] / f64(n),
			bench.gpu[.World] / f64(n),
			bench.gpu[.Props] / f64(n),
			bench.gpu[.Decals] / f64(n),
			bench.gpu[.Viewmodel] / f64(n),
			bench.gpu[.Hud] / f64(n),
		)
	}

	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical_device, &props)

	// The present mode actually obtained, not the one asked for: under a
	// compositor without tearing control the request is quietly ignored, the
	// numbers are pinned to the refresh rate, and a flat 60 would otherwise read
	// as a result.
	log.infof(
		"{}{} msaa={} shadows={}x{} present={} device=\"{}\"",
		b,
		gpu,
		g.msaa_samples,
		shadow_cascades(),
		shadow_resolution(),
		g.present_mode,
		string(cstring(&props.deviceName[0])),
	)

	os.exit(0)
}
