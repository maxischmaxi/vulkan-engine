package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

// Persistence for every settings struct, in one registry. Each key names its
// parse and format side by side, so load and save cannot drift the way a
// separate parser and a fixed template once could. The file format stays
// key=value INI: a player whose config made the game unlaunchable can fix it
// in any text editor.

All_Settings :: struct {
	render:    Render_Settings,
	audio:     Audio_Settings,
	game:      Game_Settings,
	crosshair: Crosshair_Style,
	window:    Window_Settings,
}

Setting_Key :: struct {
	key:    string,
	early:  bool, // parsed by load_window_settings, before the window exists
	parse:  proc(s: ^All_Settings, value: string) -> bool,
	format: proc(s: ^All_Settings) -> string, // temp allocator, frame lifetime
}

// Table order is file order. `pending` stays out of the registry: it is the
// crash guard, not a setting, and is handled before parsing.
SETTING_KEYS := []Setting_Key {
	{
		key = "preset",
		parse = proc(s: ^All_Settings, v: string) -> bool {
			for p in Preset {
				if !strings.equal_fold(v, fmt.tprint(p)) do continue
				if p == .Custom {
					s.render.preset = .Custom
				} else {
					s.render = PRESETS[p]
				}
				return true
			}
			return false
		},
		format = proc(s: ^All_Settings) -> string {return fmt.tprint(s.render.preset)},
	},
	{
		key = "vsync",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.vsync = parse_flag(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprint(s.render.vsync)},
	},
	{
		key = "fps_cap",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.fps_cap = u32(max(parse_int(v), 0));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.render.fps_cap)},
	},
	{
		key = "msaa",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.msaa = u8(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.render.msaa)},
	},
	{
		key = "render_scale",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.render_scale = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.2f", s.render.render_scale)},
	},
	{
		key = "shadow_cascades",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.shadow_cascades = u8(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.render.shadow_cascades)},
	},
	{
		key = "shadow_resolution",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.shadow_resolution = u16(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.render.shadow_resolution)},
	},
	{
		key = "shadow_pcf",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.shadow_pcf = u8(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.render.shadow_pcf)},
	},
	{
		key = "anisotropy",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.anisotropy = u8(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.render.anisotropy)},
	},
	{
		key = "mip_lod_bias",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.mip_lod_bias = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.2f", s.render.mip_lod_bias)},
	},
	{
		key = "gpu_timing",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.render.gpu_timing = parse_flag(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprint(s.render.gpu_timing)},
	},
	{
		key = "volume_master",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.audio.master = parse_percent(v);return true},
		format = proc(s: ^All_Settings) -> string {return format_percent(s.audio.master)},
	},
	{
		key = "volume_music",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.audio.music = parse_percent(v);return true},
		format = proc(s: ^All_Settings) -> string {return format_percent(s.audio.music)},
	},
	{
		key = "volume_effects",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.audio.effects = parse_percent(v);return true},
		format = proc(s: ^All_Settings) -> string {return format_percent(s.audio.effects)},
	},
	{
		key = "volume_ambient",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.audio.ambient = parse_percent(v);return true},
		format = proc(s: ^All_Settings) -> string {return format_percent(s.audio.ambient)},
	},
	{
		key = "sensitivity",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.game.sensitivity = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.2f", s.game.sensitivity)},
	},
	{
		key = "zoom_sensitivity",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.game.zoom_sensitivity = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.2f", s.game.zoom_sensitivity)},
	},
	{
		key = "invert_y",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.game.invert_y = parse_flag(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprint(s.game.invert_y)},
	},
	{
		key = "fov",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.game.fov = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.0f", s.game.fov)},
	},
	{
		key = "hud_scale",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.game.hud_scale = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.2f", s.game.hud_scale)},
	},
	{
		key = "brightness",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.game.brightness = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.2f", s.game.brightness)},
	},
	{
		key = "crosshair_size",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.size = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.1f", s.crosshair.size)},
	},
	{
		key = "crosshair_thickness",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.thickness = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.1f", s.crosshair.thickness)},
	},
	{
		key = "crosshair_gap",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.gap = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.1f", s.crosshair.gap)},
	},
	{
		key = "crosshair_outline",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.outline = parse_f32(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%.1f", s.crosshair.outline)},
	},
	{
		key = "crosshair_dot",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.dot = parse_flag(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprint(s.crosshair.dot)},
	},
	{
		key = "crosshair_t",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.t_style = parse_flag(v);return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprint(s.crosshair.t_style)},
	},
	// Stored as sRGB bytes -- what a colour picker shows -- and converted to
	// the linear values the shader wants on the way in and out.
	{
		key = "crosshair_color_r",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.color.r = srgb_byte_to_linear(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", linear_to_srgb_byte(s.crosshair.color.r))},
	},
	{
		key = "crosshair_color_g",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.color.g = srgb_byte_to_linear(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", linear_to_srgb_byte(s.crosshair.color.g))},
	},
	{
		key = "crosshair_color_b",
		parse = proc(s: ^All_Settings, v: string) -> bool {s.crosshair.color.b = srgb_byte_to_linear(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", linear_to_srgb_byte(s.crosshair.color.b))},
	},
	{
		key = "window_mode",
		early = true,
		parse = proc(s: ^All_Settings, v: string) -> bool {
			s.window.mode = strings.equal_fold(v, "fullscreen") ? .Fullscreen : .Windowed
			return true
		},
		format = proc(s: ^All_Settings) -> string {
			return s.window.mode == .Fullscreen ? "fullscreen" : "windowed"
		},
	},
	{
		key = "window_width",
		early = true,
		parse = proc(s: ^All_Settings, v: string) -> bool {s.window.width = i32(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.window.width)},
	},
	{
		key = "window_height",
		early = true,
		parse = proc(s: ^All_Settings, v: string) -> bool {s.window.height = i32(parse_int(v));return true},
		format = proc(s: ^All_Settings) -> string {return fmt.tprintf("%d", s.window.height)},
	},
}

// ------------------------------------------------------------------ helpers

@(private = "file")
parse_flag :: proc(v: string) -> bool {
	return v == "1" || v == "true"
}

@(private = "file")
parse_int :: proc(v: string) -> int {
	n, _ := strconv.parse_int(v)
	return n
}

@(private = "file")
parse_f32 :: proc(v: string) -> f32 {
	f, _ := strconv.parse_f32(v)
	return f
}

@(private = "file")
parse_percent :: proc(v: string) -> f32 {
	return clamp(f32(parse_int(v)) / 100, 0, 1)
}

@(private = "file")
format_percent :: proc(v: f32) -> string {
	return fmt.tprintf("%d", int(v * 100 + 0.5))
}

srgb_byte_to_linear :: proc(b: int) -> f32 {
	c := f32(clamp(b, 0, 255)) / 255
	return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
}

linear_to_srgb_byte :: proc(l: f32) -> int {
	c := clamp(l, 0, 1)
	s := c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1.0 / 2.4) - 0.055
	return int(s * 255 + 0.5)
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

collect_settings :: proc() -> All_Settings {
	return {
		render = settings,
		audio = audio_settings,
		game = game_settings,
		crosshair = crosshair,
		window = window_settings,
	}
}

@(private = "file")
commit_settings :: proc(s: ^All_Settings) {
	settings = clamp_to_device(s.render)
	audio_settings = s.audio
	game_settings = clamp_game_settings(s.game)
	crosshair = clamp_crosshair_style(s.crosshair)
	window_settings = clamp_window_settings(s.window)
}

// Whether the render values still match the preset they claim. fps_cap and
// gpu_timing are not quality dials and never make a preset custom.
@(private = "file")
preset_equivalent :: proc(s: Render_Settings) -> bool {
	if s.preset == .Custom do return true
	ref := PRESETS[s.preset]
	cmp := s
	cmp.fps_cap = ref.fps_cap
	cmp.gpu_timing = ref.gpu_timing
	return cmp == ref
}

load_settings :: proc() {
	blob := collect_settings()
	blob.render = clamp_to_device(PRESETS[detect_preset()])
	blob.render.gpu_timing = cli.gpu_timing

	path := config_path()
	if path == "" do return

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		commit_settings(&blob)
		log.infof("No settings file; detected {} for this GPU", settings.preset)
		save_settings()
		force_bench_overrides()
		return
	}

	text := string(data)

	// A pipeline-scope change that hangs the driver would otherwise be
	// reapplied on every launch from here on. The marker is armed before such
	// a change and cleared once a frame has actually been presented.
	if strings.contains(text, "pending=1") {
		log.warn("Last run did not survive a settings change; falling back to Low")
		blob.render = clamp_to_device(PRESETS[.Low])
		commit_settings(&blob)
		save_settings()
		return
	}

	for line in strings.split_lines_iterator(&text) {
		entry := strings.trim_space(line)
		if len(entry) == 0 || entry[0] == '#' do continue

		eq := strings.index_byte(entry, '=')
		if eq < 0 do continue

		key := strings.trim_space(entry[:eq])
		value := strings.trim_space(entry[eq + 1:])
		if key == "pending" do continue

		found := false
		for &reg in SETTING_KEYS {
			if reg.key != key do continue
			found = reg.parse(&blob, value)
			break
		}
		if !found do log.warnf("Ignoring unknown setting {}", key)
	}

	// A hand-edited quality value is no longer the preset it claims; an
	// untouched preset survives the round trip.
	if !preset_equivalent(blob.render) do blob.render.preset = .Custom

	commit_settings(&blob)
	force_bench_overrides()
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

// Reads only the early keys, before the window (and the device) exists. The
// full load_settings re-parses them harmlessly later.
load_window_settings :: proc() {
	path := config_path()
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return

	blob: All_Settings
	blob.window = window_settings

	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		entry := strings.trim_space(line)
		if len(entry) == 0 || entry[0] == '#' do continue
		eq := strings.index_byte(entry, '=')
		if eq < 0 do continue

		key := strings.trim_space(entry[:eq])
		value := strings.trim_space(entry[eq + 1:])
		for &reg in SETTING_KEYS {
			if reg.early && reg.key == key {
				reg.parse(&blob, value)
				break
			}
		}
	}
	window_settings = clamp_window_settings(blob.window)
}

// Measuring against a vsync is measuring the monitor, and a moved FOV or HUD
// would make numbers incomparable across runs. Not written back to the config
// -- a benchmark run must not change what the next normal run does.
@(private = "file")
force_bench_overrides :: proc() {
	if cli.bench == 0 do return

	settings.vsync = false
	settings.fps_cap = 0
	game_settings.fov = 90
	game_settings.hud_scale = 1
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

	blob := collect_settings()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"# dust2 settings. Delete this file to go back to the detected defaults.\n",
	)
	for &reg in SETTING_KEYS {
		fmt.sbprintf(&b, "%s=%s\n", reg.key, reg.format(&blob))
	}
	fmt.sbprintf(&b, "pending=%d\n", pending ? 1 : 0)

	// Written aside and renamed: a crash halfway through a write would
	// otherwise leave a truncated file, and the next launch would parse it.
	temp := config_path(".tmp")
	if err := os.write_entire_file(temp, transmute([]byte)strings.to_string(b)); err != nil {
		log.warnf("Cannot write {}: {}", temp, err)
		return
	}
	if err := os.rename(temp, path); err != nil {
		log.warnf("Cannot replace {}: {}", path, err)
	}
}

// ---------------------------------------------------------------- crash guard

// Armed before a risky (pipeline/swapchain) rebuild, cleared by the first
// successful present after it. A driver hang in between leaves pending=1 on
// disk and the next launch falls back to Low.
settings_guard_armed: bool

settings_guard_clear :: proc() {
	if !settings_guard_armed do return
	settings_guard_armed = false
	save_settings(false)
}
