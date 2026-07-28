package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
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
	if old.msaa != new.msaa ||
	   old.vsync != new.vsync ||
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
	save_settings()

	switch scope {
	case .None, .Live:
	// nothing to rebuild
	case .Sampler:
		rebuild_samplers()
	case .Pipelines:
		rebuild_renderer(false)
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
	create_decal_pipeline()
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
	destroy_pipeline(prop_renderer.pipeline)
	destroy_pipeline(model_renderer.pipeline)
	destroy_pipeline(decal_renderer.pipeline)
	destroy_pipeline(hud_renderer.quad_pipeline)
	destroy_pipeline(hud_renderer.pipeline)
	destroy_pipeline(damage_renderer.pipeline)
}

// ------------------------------------------------------------------ storage

@(private = "file")
CONFIG_DIR :: "dust2"

@(private = "file")
CONFIG_NAME :: "settings.ini"

@(private = "file")
config_path :: proc(suffix := "") -> string {
	dir := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if dir == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return ""
		dir = fmt.tprintf("%s/.config", home)
	}
	return fmt.tprintf("%s/%s/%s%s", dir, CONFIG_DIR, CONFIG_NAME, suffix)
}

// INI rather than JSON or TOML: Odin core ships no TOML parser, and more to the
// point a player whose config has made the game unlaunchable can fix key=value
// in any text editor. Unknown keys are warned about and kept out of the way, so
// downgrading a build does not wipe the file.
load_settings :: proc() {
	settings = clamp_to_device(PRESETS[detect_preset()])
	settings.gpu_timing = cli.gpu_timing

	path := config_path()
	if path == "" do return

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.infof("No settings file; detected {} for this GPU", settings.preset)
		save_settings()
		force_bench_present()
		return
	}

	text := string(data)

	// A pipeline-scope change that hangs the driver would otherwise be
	// reapplied on every launch from here on. The marker is written before such
	// a change is applied and cleared once a frame has actually been presented.
	if strings.contains(text, "pending=1") {
		log.warn("Last run did not survive a settings change; falling back to Low")
		settings = clamp_to_device(PRESETS[.Low])
		save_settings()
		return
	}

	loaded := settings
	for line in strings.split_lines_iterator(&text) {
		entry := strings.trim_space(line)
		if len(entry) == 0 || entry[0] == '#' do continue

		eq := strings.index_byte(entry, '=')
		if eq < 0 do continue

		key := strings.trim_space(entry[:eq])
		value := strings.trim_space(entry[eq + 1:])
		if !apply_setting_key(&loaded, key, value) {
			log.warnf("Ignoring unknown setting {}", key)
		}
	}

	// Anything hand-edited is no longer any preset in particular.
	settings = clamp_to_device(loaded)
	force_bench_present()
	log.infof(
		"Settings: {} -- scale {:.2f}, msaa {}x, shadows {}x{} pcf {}, aniso {}x, vsync {}",
		settings.preset,
		settings.render_scale,
		settings.msaa,
		settings.shadow_cascades,
		settings.shadow_resolution,
		settings.shadow_pcf,
		settings.anisotropy,
		settings.vsync,
	)
}

// Measuring against a vsync is measuring the monitor. Not written back to the
// config -- a benchmark run must not change what the next normal run does.
@(private = "file")
force_bench_present :: proc() {
	if cli.bench == 0 do return

	settings.vsync = false
	settings.fps_cap = 0
}

@(private = "file")
apply_setting_key :: proc(s: ^Render_Settings, key, value: string) -> bool {
	number, _ := strconv.parse_int(value)
	flag := value == "1" || value == "true"

	switch key {
	case "preset":
		for p in Preset {
			if !strings.equal_fold(value, fmt.tprint(p)) do continue
			if p == .Custom do break
			s^ = PRESETS[p]
			return true
		}
		return true
	case "vsync":
		s.vsync = flag
	case "fps_cap":
		s.fps_cap = u32(max(number, 0))
	case "msaa":
		s.msaa = u8(number)
	case "render_scale":
		scale, _ := strconv.parse_f32(value)
		s.render_scale = scale
	case "shadow_cascades":
		s.shadow_cascades = u8(number)
	case "shadow_resolution":
		s.shadow_resolution = u16(number)
	case "shadow_pcf":
		s.shadow_pcf = u8(number)
	case "anisotropy":
		s.anisotropy = u8(number)
	case "mip_lod_bias":
		bias, _ := strconv.parse_f32(value)
		s.mip_lod_bias = bias
	case "gpu_timing":
		s.gpu_timing = flag
	case "pending":
	// handled before parsing
	case:
		return false
	}

	s.preset = .Custom
	return true
}

save_settings :: proc(pending := false) {
	path := config_path()
	if path == "" do return

	dir := path[:strings.last_index_byte(path, '/')]
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {
			log.warnf("Cannot create {}: {}", dir, err)
			return
		}
	}

	text := fmt.tprintf(
		`# dust2 render settings. Delete this file to go back to the detected defaults.
preset=%v
vsync=%v
fps_cap=%d
msaa=%d
render_scale=%.2f
shadow_cascades=%d
shadow_resolution=%d
shadow_pcf=%d
anisotropy=%d
mip_lod_bias=%.2f
gpu_timing=%v
pending=%d
`,
		settings.preset,
		settings.vsync,
		settings.fps_cap,
		settings.msaa,
		settings.render_scale,
		settings.shadow_cascades,
		settings.shadow_resolution,
		settings.shadow_pcf,
		settings.anisotropy,
		settings.mip_lod_bias,
		settings.gpu_timing,
		pending ? 1 : 0,
	)

	// Written aside and renamed: a crash halfway through a write would
	// otherwise leave a truncated file, and the next launch would parse it.
	temp := config_path(".tmp")
	if err := os.write_entire_file(temp, transmute([]byte)text); err != nil {
		log.warnf("Cannot write {}: {}", temp, err)
		return
	}
	if err := os.rename(temp, path); err != nil {
		log.warnf("Cannot replace {}: {}", path, err)
	}
}
