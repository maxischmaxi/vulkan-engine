package main

import "vendor:glfw"

// Where the frame's CPU time goes.
//
// Two of these zones are worth more than all the others together. Wait_Fence is
// how long the CPU sat waiting for the GPU to finish an earlier frame, and
// Cap_Sleep is how long it deliberately did nothing. Large Wait_Fence means the
// GPU is the bottleneck, large Cap_Sleep means neither is and there is headroom,
// and both small with a large everything-else means the CPU is. Which of those
// three is true decides what is worth optimising at all, and the fps counter
// cannot tell them apart.
//
// The zones are wall-clock and non-overlapping by construction: begin closes
// nothing, end attributes elapsed time to whatever was open. Nesting is not
// supported and not wanted -- this is a budget, not a call tree.

Cpu_Zone :: enum {
	Tick, // simulation steps
	Build_Frame, // scene assembly and HUD
	Wait_Fence, // blocked on the GPU
	Upload, // per-frame buffer writes
	Record, // command buffer recording
	Present, // submit and present
	Cap_Sleep, // idling to hold the frame rate cap
	Other, // everything not claimed above
}

Cpu_Timer :: struct {
	open:      Cpu_Zone,
	mark:      f64,
	frame:     [Cpu_Zone]f32, // this frame, milliseconds
	smoothed:  [Cpu_Zone]f32, // exponential moving average, for the overlay
	collected: bool,
}

cpu_timer: Cpu_Timer

// Slow enough to read, fast enough to see a change land.
@(private = "file")
CPU_SMOOTHING :: f32(0.05)

// Closes whatever zone was open and opens this one.
cpu_zone :: proc(zone: Cpu_Zone) {
	now := glfw.GetTime()
	cpu_timer.frame[cpu_timer.open] += f32(now - cpu_timer.mark) * 1000
	cpu_timer.open = zone
	cpu_timer.mark = now
}

// Start of a frame: bank the tail of the previous one, then reset.
cpu_frame_begin :: proc() {
	cpu_zone(.Other)

	for zone in Cpu_Zone {
		cpu_timer.smoothed[zone] +=
			(cpu_timer.frame[zone] - cpu_timer.smoothed[zone]) * CPU_SMOOTHING
		cpu_timer.frame[zone] = 0
	}
}

cpu_timer_total :: proc() -> f32 {
	total: f32
	for zone in Cpu_Zone do total += cpu_timer.smoothed[zone]
	return total
}
