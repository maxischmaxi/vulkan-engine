package game

import "core:time"

// The simulation runs at a fixed rate and the renderer interpolates between the
// last two states. Counter-strike works this way for a reason: movement and hit
// results must not depend on how fast the machine draws, and a deterministic
// step is the only thing a network protocol or a regression test can agree on.
//
// Aiming deliberately stays outside the tick. Mouse input is applied to the
// camera the moment it arrives, because a tick of latency between moving the
// mouse and the view following is exactly what a shooter must not have.
//
// core:time rather than glfw.GetTime, because the server has no window to ask.

TICK_RATE :: 64
TICK_DT :: 1.0 / f32(TICK_RATE)

// After a long stall -- a debugger breakpoint, a compositor hiccup -- the
// accumulator would otherwise hold seconds of simulation and the game would
// spend minutes catching up. Dropping the excess loses time, which is the
// lesser problem.
MAX_CATCHUP_TICKS :: 8

Clock :: struct {
	last:        time.Tick,
	accumulator: f32,
	alpha:       f32, // how far between the last two ticks the current frame sits
	frame_dt:    f32, // real seconds since the last frame, for effects and cooldowns
	tick_count:  u64,
}

clock: Clock

init_clock :: proc() {
	clock.last = time.tick_now()
}

// Advances real time and returns how many simulation steps are due.
advance_clock :: proc() -> int {
	now := time.tick_now()
	clock.frame_dt = f32(min(time.duration_seconds(time.tick_diff(clock.last, now)), 0.25))
	clock.last = now

	clock.accumulator += clock.frame_dt

	steps := 0
	for clock.accumulator >= TICK_DT && steps < MAX_CATCHUP_TICKS {
		clock.accumulator -= TICK_DT
		steps += 1
	}

	if clock.accumulator >= TICK_DT {
		// still behind after the cap: throw the backlog away rather than
		// spiralling
		clock.accumulator = 0
	}

	clock.alpha = clock.accumulator / TICK_DT
	clock.tick_count += u64(steps)
	return steps
}
