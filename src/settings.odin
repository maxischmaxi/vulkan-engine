package main

import vk "vendor:vulkan"

// Everything the renderer reads to decide how much work to do.
//
// The point of this file is that nothing else may decide. MSAA and anisotropy
// both ended up pinned to whatever the device reported as its maximum, with no
// way to say otherwise, because the code that needed a number asked the driver
// for one right there -- which is fine on the machine it was written on and
// nowhere else. Every such number now lives here, and the ones that hurt on weak
// hardware are the ones the player can turn down.
//
// Scaling quality is also the honest answer to "make it run on an old PC". The
// shadow pass alone rasterises eight times as many pixels as the screen does; no
// amount of tightening the code around it competes with rendering it at half the
// resolution.

Preset :: enum u8 {
	Custom,
	Potato,
	Low,
	Medium,
	High,
	Ultra,
}

Render_Settings :: struct {
	preset:            Preset,

	// ------------------------------------------------------------- present
	vsync:             bool, // FIFO when set, MAILBOX or IMMEDIATE when not
	fps_cap:           u32, // 0 leaves it uncapped

	// ------------------------------------------------------- rasterisation
	msaa:              u8, // 1 / 2 / 4 / 8, clamped to what the device offers
	// The scene is rendered at this fraction of the window and stretched back up
	// on the way to the screen. It scales every fragment cost there is at once,
	// which is why it is the strongest dial in this struct on a weak GPU, and the
	// HUD is drawn after the stretch so text stays sharp.
	render_scale:      f32, // 0.50 .. 1.00

	// ------------------------------------------------------------- shadows
	shadow_cascades:   u8, // 0 turns shadows off entirely
	shadow_resolution: u16,
	shadow_pcf:        u8, // taps per lookup: 1, 4 or 9

	// ------------------------------------------------------------ texturing
	anisotropy:        u8, // 1 / 2 / 4 / 8 / 16
	mip_lod_bias:      f32, // positive is blurrier and cheaper

	// ---------------------------------------------------------- diagnostics
	gpu_timing:        bool,
}

settings: Render_Settings

// Which of those a change can be applied to, and what it costs to apply.
Settings_Scope :: enum u8 {
	None,
	Live, // next frame picks it up
	Sampler, // idle, rebuild the sampler, rewrite one descriptor
	Pipelines, // idle, rebuild render targets, shadow map and every pipeline
	Swapchain, // all of the above plus the swapchain -- the present mode lives there
}

PRESETS := [Preset]Render_Settings {
	// never selected; the field exists so a hand-edited config keeps its values
	.Custom = {},
	.Potato = {
		preset = .Potato,
		vsync = true,
		render_scale = 0.65,
		msaa = 1,
		shadow_cascades = 0,
		shadow_resolution = 512,
		shadow_pcf = 1,
		anisotropy = 1,
		mip_lod_bias = 0.5,
	},
	.Low = {
		preset = .Low,
		vsync = true,
		render_scale = 0.80,
		msaa = 1,
		shadow_cascades = 2,
		shadow_resolution = 1024,
		shadow_pcf = 1,
		anisotropy = 2,
	},
	.Medium = {
		preset = .Medium,
		vsync = true,
		render_scale = 1.0,
		msaa = 2,
		shadow_cascades = 3,
		shadow_resolution = 1024,
		shadow_pcf = 4,
		anisotropy = 4,
	},
	.High = {
		preset = .High,
		vsync = true,
		render_scale = 1.0,
		msaa = 4,
		shadow_cascades = 3,
		shadow_resolution = 2048,
		shadow_pcf = 9,
		anisotropy = 8,
	},
	.Ultra = {
		preset = .Ultra,
		vsync = true,
		render_scale = 1.0,
		msaa = 4,
		shadow_cascades = 3,
		shadow_resolution = 2048,
		shadow_pcf = 9,
		anisotropy = 16,
	},
}

// Deliberately coarse, and deliberately pessimistic.
//
// There is no performance number anywhere in VkPhysicalDeviceProperties. Not a
// core count, not a clock, not a bandwidth figure. The limits that look like
// they might stand in for one do not: maxComputeSharedMemorySize is larger on
// this machine's integrated GPU than on its discrete one, and maxImageDimension2D
// is 16384 on everything. Vendor ID spans a GT 710 and an RTX 5090.
//
// So: guess low, say so in the log, and make overriding it one keypress. Being
// wrong downward costs a trip to the menu; being wrong upward costs the session.
detect_preset :: proc() -> Preset {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical_device, &props)

	GIB :: u64(1024 * 1024 * 1024)
	vram := device_local_bytes(g.physical_device)

	if props.deviceType != .DISCRETE_GPU do return .Low
	if vram < 3 * GIB do return .Low
	if vram < 6 * GIB do return .Medium
	return .High
}

// What the device will actually honour. Called on every load and every change,
// so an unreachable value in a config file becomes a reachable one rather than
// a validation error.
clamp_to_device :: proc(s: Render_Settings) -> Render_Settings {
	out := s

	out.msaa = clamp_msaa(out.msaa)
	out.anisotropy = u8(clamp(f32(out.anisotropy), 1, g.max_anisotropy))
	out.shadow_cascades = min(out.shadow_cascades, SHADOW_CASCADES_MAX)
	out.shadow_resolution = clamp(out.shadow_resolution, 256, 4096)
	out.mip_lod_bias = clamp(out.mip_lod_bias, 0, 4)
	out.render_scale = clamp(out.render_scale, 0.5, 1.0)

	switch {
	case out.shadow_pcf <= 1:
		out.shadow_pcf = 1
	case out.shadow_pcf <= 4:
		out.shadow_pcf = 4
	case:
		out.shadow_pcf = 9
	}

	return out
}

// Which parts of the renderer a change reaches. Ordered, so a diff can take the
// most expensive answer.
settings_scope :: proc(old, new: Render_Settings) -> Settings_Scope {
	// The present mode is baked into the swapchain at creation, so a vsync
	// change that only rebuilt pipelines would not take effect until some
	// unrelated resize recreated it.
	if old.vsync != new.vsync do return .Swapchain
	if old.msaa != new.msaa ||
	   old.render_scale != new.render_scale ||
	   old.shadow_cascades != new.shadow_cascades ||
	   old.shadow_resolution != new.shadow_resolution ||
	   old.shadow_pcf != new.shadow_pcf {
		return .Pipelines
	}
	if old.anisotropy != new.anisotropy || old.mip_lod_bias != new.mip_lod_bias {
		return .Sampler
	}
	if old.fps_cap != new.fps_cap || old.gpu_timing != new.gpu_timing {
		return .Live
	}
	return .None
}

apply_settings :: proc(next: Render_Settings) {
	wanted := clamp_to_device(next)
	scope := settings_scope(settings, wanted)
	if scope == .None do return

	settings = wanted
	gpu_timer.enabled = settings.gpu_timing && gpu_timer.supported

	// A rebuild that hangs the driver must not be reapplied on every launch:
	// the pending marker goes to disk first and the next successful present
	// clears it (settings_guard_clear in the present path).
	risky := scope == .Pipelines || scope == .Swapchain
	save_settings(pending = risky)
	if risky do settings_guard_armed = true

	switch scope {
	case .None, .Live:
	// nothing to rebuild
	case .Sampler:
		rebuild_samplers()
	case .Pipelines:
		rebuild_renderer(false)
	case .Swapchain:
		rebuild_renderer(true)
	}
}

// Everything downstream of the device, rebuilt in the order main() creates it.
//
// recreate_swapchain is this with swapchain_too set, and that is the whole
// point: dragging a window edge exercises the settings rebuild constantly, so
// the path cannot quietly rot between the rare times a setting changes.
rebuild_renderer :: proc(swapchain_too: bool) {
	vk_check(vk.DeviceWaitIdle(g.device))

	destroy_all_pipelines()
	destroy_shadow_map()
	destroy_render_targets()

	if swapchain_too {
		destroy_swapchain_views()

		old := g.swapchain
		create_swapchain(old)
		vk.DestroySwapchainKHR(g.device, old, nil)

		get_swapchain_images()
		create_image_views()
		recreate_render_finished_semaphores()
	}

	g.msaa_samples = pick_msaa_samples()
	create_shadow_map()
	create_render_targets()

	// The shadow image is new, so the descriptors that point at it are stale.
	write_frame_sets()
	create_all_pipelines()

	log_camera_fov()
}

create_all_pipelines :: proc() {
	create_world_pipeline()
	create_shadow_pipelines()
	create_prop_pipeline()
	create_model_pipeline()
	create_character_pipeline()
	create_decal_pipeline()
	create_tracer_pipeline()
	create_hud_pipeline()
	create_hud_quad_pipeline()
	create_damage_pipeline()
}

destroy_all_pipelines :: proc() {
	destroy_pipeline(world_renderer.pipeline)
	destroy_pipeline(world_renderer.overdraw_pipe)
	// zero handles are legal to destroy, so this needs no flag check
	destroy_pipeline(world_renderer.prepass_pipe)
	world_renderer.prepass_pipe = {}
	destroy_pipeline(shadow.world_pipe)
	destroy_pipeline(shadow.prop_pipe)
	destroy_pipeline(shadow.model_pipe)
	destroy_pipeline(shadow.character_pipe)
	destroy_pipeline(prop_renderer.pipeline)
	destroy_pipeline(model_renderer.pipeline)
	destroy_pipeline(character_renderer.pipeline)
	destroy_pipeline(decal_renderer.pipeline)
	destroy_pipeline(tracer_renderer.pipeline)
	destroy_pipeline(hud_renderer.quad_pipeline)
	destroy_pipeline(hud_renderer.pipeline)
	destroy_pipeline(damage_renderer.pipeline)
}
