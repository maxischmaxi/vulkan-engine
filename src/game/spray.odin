package game

import "core:math"

// Counter-strike style spray with a valorant twist: a pattern rolled fresh
// per burst from a seed, sampled at a fractional burst depth that decays over
// time. The climb is deterministic so pulling down is always the right
// correction and taps keep their laser; past det_shots the yaw wanders inside
// a hard bound, so no two sprays land the same and nobody can learn the
// pattern shot-for-shot. Both ends build the identical points from
// (params, seed) -- only the seed and the depth ever cross the wire.
//
// Points are CUMULATIVE offsets in degrees, {d_yaw, d_pitch}: d_pitch > 0
// kicks the bullet up, d_yaw > 0 kicks it left (yaw turns counter-clockwise,
// basis.odin). Point 0 is always {0, 0} -- the first shot of a burst is the
// laser it always was.

// The clamp both ends must share, or a sky-facing sprayer desyncs.
SPRAY_MAX_PITCH :: 89.5

// Largest magazine that carries a pattern.
SPRAY_MAX_POINTS :: 30

// Depth decay past the grace window: exponential for the feathering feel
// (deep sprays pay back fast), linear so the depth reaches an exact 0 in
// bounded time -- 0 is the seed-reroll and adoption condition, and a wire
// quantizer needs it to be reachable.
SPRAY_DECAY_EXP :: 6.0 // 1/s
SPRAY_DECAY_LIN :: 3.0 // depth per second

// cool saturates here; adoption guards compare against fractions of it.
SPRAY_COOL_CAP :: 4.0

// How a weapon's pattern is generated, in degrees and shots.
Spray_Params :: struct {
	climb_pitch:  f32, // total upward pull over the climb
	climb_shots:  int, // shots to reach the plateau; 0 = no pattern
	det_shots:    int, // seed-independent prefix, masks seed latency
	det_yaw:      f32, // zigzag amplitude at the end of the prefix
	yaw_sway:     f32, // hard |yaw| bound on the plateau walk
	yaw_step:     f32, // walk step scale per shot
	yaw_momentum: f32, // 0..1 velocity carried shot to shot
	pitch_jitter: f32, // plateau pitch wobble, +- degrees
	grace:        f32, // seconds after a shot before decay begins
}

// One pawn's burst: server truth and client mirror share this shape.
Spray_Track :: struct {
	progress: f32, // 0..mag_size shots deep, fractional under decay
	cool:     f32, // seconds since the last shot, saturating
	seed:     u32, // rolled at burst start, stale between bursts
	points:   [SPRAY_MAX_POINTS][2]f32, // cumulative {d_yaw, d_pitch}
}

// Tiny stand-alone generator: core:math/rand internals may drift between
// builds, this cannot -- and client and server must agree bit for bit.
@(private = "file")
splitmix32 :: proc(state: ^u32) -> u32 {
	state^ += 0x9E3779B9
	z := state^
	z = (z ~ (z >> 16)) * 0x21F0AAAD
	z = (z ~ (z >> 15)) * 0x735A2D97
	return z ~ (z >> 15)
}

// Uniform in [-1, 1).
@(private = "file")
sym :: proc(state: ^u32) -> f32 {
	return f32(splitmix32(state) >> 8) / f32(1 << 24) * 2 - 1
}

// Fast start that saturates into the plateau; strictly increasing, so the
// climb never dips.
@(private = "file")
climb_ease :: proc(t: f32) -> f32 {
	s := t * t * (3 - 2 * t)
	return 0.35 * t + 0.65 * s
}

// The whole burst from (params, seed). Point 0 stays {0, 0} -- the first shot
// of a burst is the laser it always was. Pitch is deterministic through the
// climb, then wobbles around the plateau; yaw zigzags seed-independently for
// det_shots, then walks with momentum inside +-yaw_sway, reflecting off the
// bound so it wanders instead of sticking.
spray_build_points :: proc(par: Spray_Params, seed: u32, points: ^[SPRAY_MAX_POINTS][2]f32) {
	points^ = {}
	if par.climb_shots <= 0 do return

	state := seed
	yaw, v: f32
	for k in 1 ..< SPRAY_MAX_POINTS {
		pitch: f32
		if k <= par.climb_shots {
			pitch = par.climb_pitch * climb_ease(f32(k) / f32(par.climb_shots))
		} else {
			pitch = par.climb_pitch + sym(&state) * par.pitch_jitter
		}
		if k < par.det_shots {
			sign := f32(k & 1 == 1 ? -1 : 1)
			yaw = sign * par.det_yaw * f32(k) / f32(par.det_shots)
		} else {
			v = v * par.yaw_momentum + sym(&state) * par.yaw_step - yaw * 0.12
			yaw += v
			if abs(yaw) > par.yaw_sway {
				yaw = clamp(yaw, -par.yaw_sway, par.yaw_sway)
				v = -v * 0.5
			}
		}
		points[k] = {yaw, pitch}
	}
}

// The pattern at a fractional depth: linear between integer points, clamped to
// the magazine's last one. Depth 0 is bit-exact {0, 0}.
spray_point_at :: proc(points: ^[SPRAY_MAX_POINTS][2]f32, progress: f32, mag_size: int) -> [2]f32 {
	if progress <= 0 do return {0, 0}
	last := min(mag_size, SPRAY_MAX_POINTS) - 1
	if last < 0 do return {0, 0}
	p := min(progress, f32(last))
	lo := int(p)
	hi := min(lo + 1, last)
	t := p - f32(lo)
	return points[lo] + (points[hi] - points[lo]) * t
}

// Where the track's pattern currently sits -- the ballistic offset between
// shots, and (scaled) the viewpunch target.
spray_track_offset :: proc(t: ^Spray_Track, mag_size: int) -> [2]f32 {
	return spray_point_at(&t.points, t.progress, mag_size)
}

// One trigger pull: roll a fresh burst when the track is empty, sample at the
// pre-increment depth (full-rate fire lands exactly on integer points), then
// deepen by one shot. fresh_seed is only consumed at burst start, so callers
// can guard the draw and keep their rng stream untouched mid-burst.
spray_track_shot :: proc(t: ^Spray_Track, par: Spray_Params, mag_size: int, fresh_seed: u32) -> [2]f32 {
	if t.progress == 0 {
		t.seed = fresh_seed
		spray_build_points(par, fresh_seed, &t.points)
	}
	off := spray_point_at(&t.points, t.progress, mag_size)
	t.progress = min(t.progress + 1, f32(max(mag_size, 1)))
	t.cool = 0
	return off
}

// The always-on cooloff. Inside the grace window the depth holds, so full-rate
// fire never decays mid-burst; past it the depth slides down the pattern the
// way it went up -- the continuous replacement for the old hard reset.
spray_track_decay :: proc(t: ^Spray_Track, par: Spray_Params, dt: f32) {
	t.cool = min(t.cool + dt, SPRAY_COOL_CAP)
	if t.progress <= 0 do return
	if t.cool < par.grace do return
	decayed := min(t.progress * math.exp(-SPRAY_DECAY_EXP * dt), t.progress - SPRAY_DECAY_LIN * dt)
	t.progress = max(decayed, 0)
}

// Switch, reload, refill: the burst is over. Points and seed stay stale --
// the next burst rebuilds them.
spray_track_reset :: proc(t: ^Spray_Track) {
	t.progress = 0
}
