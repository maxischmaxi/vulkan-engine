package main

import "vendor:glfw"

// The simulation runs at a fixed rate and the renderer interpolates between the
// last two states. Counter-strike works this way for a reason: movement and hit
// results must not depend on how fast the machine draws, and a deterministic
// step is the only thing a network protocol or a regression test can agree on.
//
// Aiming deliberately stays outside the tick. Mouse input is applied to the
// camera the moment it arrives, because a tick of latency between moving the
// mouse and the view following is exactly what a shooter must not have.

TICK_RATE :: 64
TICK_DT :: 1.0 / f32(TICK_RATE)

// After a long stall -- a debugger breakpoint, a compositor hiccup -- the
// accumulator would otherwise hold seconds of simulation and the game would
// spend minutes catching up. Dropping the excess loses time, which is the
// lesser problem.
MAX_CATCHUP_TICKS :: 8

Clock :: struct {
	last_time:   f64,
	accumulator: f32,
	alpha:       f32, // how far between the last two ticks the current frame sits
	frame_dt:    f32, // real seconds since the last frame, for effects and cooldowns
	tick_count:  u64,
}

clock: Clock

init_clock :: proc() {
	clock.last_time = glfw.GetTime()
}

// Holds the frame rate to the cap, if there is one.
//
// Sleeping the whole remainder overshoots -- the OS timer's granularity is
// coarser than a frame -- so it sleeps to a millisecond short of the deadline
// and spins out the rest. The spin is bounded by that millisecond and only ever
// runs on a machine with time to spare, which is the case where a busy loop
// costs nothing anyone will feel.
//
// Worth having even on a machine that could go faster: frames thrown away by the
// compositor still cost power, and on a part that is thermally or power limited
// that heat comes back as a lower clock.
limit_frame_rate :: proc() {
	if settings.fps_cap == 0 do return

	cpu_zone(.Cap_Sleep)
	defer cpu_zone(.Other)

	target := 1.0 / f64(settings.fps_cap)
	deadline := clock.last_time + target

	SPIN_MARGIN :: 0.001
	for {
		now := glfw.GetTime()
		if now >= deadline do return
		if deadline - now > SPIN_MARGIN {
			glfw.WaitEventsTimeout(deadline - now - SPIN_MARGIN)
		}
	}
}

// Advances real time and returns how many simulation steps are due.
advance_clock :: proc() -> int {
	now := glfw.GetTime()
	clock.frame_dt = f32(min(now - clock.last_time, 0.25))
	clock.last_time = now

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
