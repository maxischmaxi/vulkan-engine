package main

import "core:math"
import vk "vendor:vulkan"

// The directional damage vignette: one fullscreen triangle whose fragment
// shader draws a band around the whole screen boundary, thicker and hotter
// toward each hit's heading. Zero cost when nothing hurts -- the draw is
// skipped entirely.

// Scalars packed into vec4s -- std430 aligns vec4 to 16 bytes; whole vectors
// sidestep the offset question, same rule as Crosshair_Push.
Damage_Push :: struct {
	screen: [4]f32, // width, height, base ring intensity, unused
	hits:   [DAMAGE_SLOTS][4]f32, // screen dir x, y (y down), intensity, unused
	edge:   [4]f32, // vignette ring colour, from the theme
	core:   [4]f32, // lobe centre colour
}

#assert(size_of(Damage_Push) == 112) // comfortably under the 128-byte guarantee

// How bright the all-around ring is relative to the strongest lobe. Tunable.
DAMAGE_BASE_RING :: f32(0.35)

// Below this nothing is visible; skip the fullscreen draw.
@(private = "file")
DAMAGE_MIN_INTENSITY :: f32(0.005)

Damage_Renderer :: struct {
	pipeline: Pipeline,
}

damage_renderer: Damage_Renderer

create_damage_pipeline :: proc() {
	push := []vk.PushConstantRange {
		{stageFlags = {.FRAGMENT}, offset = 0, size = size_of(Damage_Push)},
	}

	damage_renderer.pipeline = build_pipeline(
	{
		name           = "hud/damage",
		vert_spv       = DAMAGE_VERT_CODE,
		frag_spv       = DAMAGE_FRAG_CODE,
		push_constants = push,
		color_formats  = {g.swapchain_format},
		// see create_hud_pipeline: the HUD block, one sample, no depth
		depth_test     = .Disabled,
		no_depth_write = true,
		blend          = .Alpha,
		cull           = .None,
	},
	)
}

// World-space hit slots -> screen-space push data. `active` is false once
// everything has faded.
@(private = "file")
build_damage_push :: proc() -> (push: Damage_Push, active: bool) {
	peak := f32(0)
	yaw := math.to_radians(camera.yaw)
	for hit, i in player_fx.hits {
		if hit.time_left <= 0 do continue
		s := hit.time_left / DAMAGE_FLASH_TIME
		intensity := hit.strength * s * s * (3 - 2 * s) // smoothstep ease-out
		if intensity < DAMAGE_MIN_INTENSITY do continue

		// Angle relative to the view: straight ahead is up the screen, and
		// the screen's y axis points down.
		relative := math.atan2(hit.dir.y, hit.dir.x) - yaw
		push.hits[i] = {-math.sin(relative), -math.cos(relative), intensity, 0}
		peak = max(peak, intensity)
	}

	base := peak * DAMAGE_BASE_RING
	if player_fx.flash > 0 {
		s := player_fx.flash / DAMAGE_FLASH_TIME
		base = max(base, s * s * (3 - 2 * s))
	}
	push.screen = {f32(g.swapchain_extent.width), f32(g.swapchain_extent.height), base, 0}
	push.edge = UI_DAMAGE_EDGE
	push.core = UI_DAMAGE_CORE
	return push, base >= DAMAGE_MIN_INTENSITY || peak >= DAMAGE_MIN_INTENSITY
}

record_damage_indicator :: proc(cmd: vk.CommandBuffer) {
	push, active := build_damage_push()
	if !active do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, damage_renderer.pipeline.pipeline)
	vk.CmdPushConstants(
		cmd,
		damage_renderer.pipeline.layout,
		{.FRAGMENT},
		0,
		size_of(Damage_Push),
		&push,
	)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
}
