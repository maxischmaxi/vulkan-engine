package main

import "core:log"
import vk "vendor:vulkan"

// How long each pass actually took on the GPU.
//
// Everything in this renderer runs sequentially on one queue, so a flat chain of
// timestamps is enough: one mark before the first pass and one after each, with
// each pass's cost being the gap to the previous mark. That deliberately cannot
// express nesting or overlap -- if a pass is ever moved to a second queue this
// stops being able to describe the frame, and it should be replaced rather than
// extended.
//
// Off unless asked for. Some drivers insert a partial pipeline flush at every
// timestamp, which would distort exactly the measurement anyone turns this on to
// take.

Gpu_Zone :: enum u32 {
	Shadow,
	World,
	Props,
	Decals,
	Viewmodel,
	Hud,
}

@(private = "file")
MARK_COUNT :: u32(len(Gpu_Zone) + 1)

Gpu_Timer :: struct {
	pools:      [MAX_FRAMES_IN_FLIGHT]vk.QueryPool,
	pending:    [MAX_FRAMES_IN_FLIGHT]bool,
	written:    u32, // marks recorded into the frame in progress
	period_ns:  f32,
	valid_mask: u64,
	ms:         [Gpu_Zone]f32, // exponential moving average
	supported:  bool,
	enabled:    bool,
}

gpu_timer: Gpu_Timer

@(private = "file")
GPU_SMOOTHING :: f32(0.05)

create_gpu_timer :: proc(enabled: bool) {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical_device, &props)

	// A queue family may report zero valid bits, meaning it cannot timestamp at
	// all. Both this and the period are per-device facts, so they are read once.
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(g.physical_device, &count, nil)
	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(g.physical_device, &count, raw_data(families))

	bits := families[g.graphics_family].timestampValidBits
	if props.limits.timestampPeriod == 0 || bits == 0 {
		log.warn("GPU timing unavailable: the graphics queue has no usable timestamps")
		return
	}

	gpu_timer.period_ns = props.limits.timestampPeriod
	gpu_timer.valid_mask = bits >= 64 ? max(u64) : (u64(1) << bits) - 1
	gpu_timer.supported = true
	gpu_timer.enabled = enabled

	pool_ci := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = MARK_COUNT,
	}
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_check(vk.CreateQueryPool(g.device, &pool_ci, nil, &gpu_timer.pools[i]))
	}

	if enabled {
		log.infof("GPU timing on: {} ns per tick, {} valid bits", gpu_timer.period_ns, bits)
	}
}

destroy_gpu_timer :: proc() {
	if !gpu_timer.supported do return

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroyQueryPool(g.device, gpu_timer.pools[i], nil)
	}
}

// Resets this frame's queries and writes the first mark. Must be called before
// any rendering block begins -- vkCmdResetQueryPool is illegal inside one.
gpu_timer_begin :: proc(cmd: vk.CommandBuffer, frame: u32) {
	gpu_timer.written = 0
	if !gpu_timer.enabled do return

	vk.CmdResetQueryPool(cmd, gpu_timer.pools[frame], 0, MARK_COUNT)
	vk.CmdWriteTimestamp2(cmd, {.TOP_OF_PIPE}, gpu_timer.pools[frame], 0)
	gpu_timer.written = 1
}

// Closes the zone that just finished. BOTTOM_OF_PIPE rather than TOP_OF_PIPE:
// the top of the pipe is reached the moment the command is read, so timing
// against it reports near-zero for every pass.
gpu_timer_mark :: proc(cmd: vk.CommandBuffer, frame: u32, zone: Gpu_Zone) {
	if !gpu_timer.enabled do return

	vk.CmdWriteTimestamp2(cmd, {.BOTTOM_OF_PIPE}, gpu_timer.pools[frame], u32(zone) + 1)
	gpu_timer.written = u32(zone) + 2
}

gpu_timer_submitted :: proc(frame: u32) {
	if gpu_timer.enabled && gpu_timer.written == MARK_COUNT do gpu_timer.pending[frame] = true
}

// Reads back the results of the last frame that used this slot. Call after the
// fence wait: that fence is what guarantees the queries have landed, which is
// why no WAIT flag is needed and why NOT_READY here would be a bug rather than
// a race.
gpu_timer_collect :: proc(frame: u32) {
	if !gpu_timer.pending[frame] do return
	gpu_timer.pending[frame] = false

	raw: [MARK_COUNT]u64
	result := vk.GetQueryPoolResults(
		g.device,
		gpu_timer.pools[frame],
		0,
		MARK_COUNT,
		size_of(raw),
		&raw[0],
		size_of(u64),
		{._64},
	)
	if result != .SUCCESS do return

	// Masking before the subtraction, not after: an unmasked high bit turns a
	// small positive difference into an enormous one.
	for zone in Gpu_Zone {
		start := raw[u32(zone)] & gpu_timer.valid_mask
		end := raw[u32(zone) + 1] & gpu_timer.valid_mask
		if end < start do continue

		ms := f32(end - start) * gpu_timer.period_ns / 1_000_000
		gpu_timer.ms[zone] += (ms - gpu_timer.ms[zone]) * GPU_SMOOTHING
	}
}

gpu_timer_total :: proc() -> f32 {
	total: f32
	for zone in Gpu_Zone do total += gpu_timer.ms[zone]
	return total
}
