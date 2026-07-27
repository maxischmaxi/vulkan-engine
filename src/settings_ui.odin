package main

import "core:fmt"
import "vendor:glfw"

// The settings menu. Not behind DEBUG_TOOLS: a player on hardware the developer
// never had is exactly who needs it, and a quality dial nobody can reach is the
// same as no dial at all.
//
// Table-driven for the reason debug.odin's action list is: a setting cannot be
// added to Render_Settings and quietly stay invisible, because this list is what
// draws it. Adding a row is the cost of adding a setting.

Setting_Row :: struct {
	label:   string,
	// The current value, already formatted. Returned through the temp allocator,
	// so it lives exactly as long as the frame that drew it.
	value:   proc() -> string,
	// Moves to the next or previous allowed value. Applied through
	// apply_settings, which decides what has to be rebuilt.
	step:    proc(direction: int),
	// Shown next to the row, so the cost of touching it is visible before it is
	// paid rather than felt as a stutter afterwards.
	rebuild: bool,
}

Settings_Ui :: struct {
	open: bool,
	row:  int,
}

settings_ui: Settings_Ui

// Cycles `current` through `values`, clamping at both ends rather than wrapping:
// holding a direction should come to rest on the extreme, not roll over to the
// opposite one.
@(private = "file")
cycle :: proc(values: []$T, current: T, direction: int) -> T {
	index := 0
	for v, i in values {
		if v == current do index = i
	}
	return values[clamp(index + direction, 0, len(values) - 1)]
}

SETTING_ROWS := []Setting_Row {
	{
		label = "PRESET",
		value = proc() -> string {return fmt.tprint(settings.preset)},
		step = proc(direction: int) {
			order := []Preset{.Potato, .Low, .Medium, .High, .Ultra}
			next := cycle(order, settings.preset, direction)
			// Custom is not in the list, so a hand-tuned config steps to the
			// nearest end rather than staying stuck.
			if settings.preset == .Custom do next = direction > 0 ? .Medium : .Low
			apply_settings(PRESETS[next])
		},
		rebuild = true,
	},
	{label = "RESOLUTION", value = proc() -> string {
			extent := scene_extent()
			return fmt.tprintf(
				"%d%%  %dx%d",
				int(settings.render_scale * 100 + 0.5),
				extent.width,
				extent.height,
			)
		}, step = proc(direction: int) {
			next := settings
			next.render_scale = cycle(
				[]f32{0.5, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9, 1.0},
				settings.render_scale,
				direction,
			)
			next.preset = .Custom
			apply_settings(next)
		}, rebuild = true},
	{label = "ANTI-ALIASING", value = proc() -> string {
			return settings.msaa <= 1 ? "OFF" : fmt.tprintf("%dx MSAA", settings.msaa)
		}, step = proc(direction: int) {
			next := settings
			next.msaa = cycle([]u8{1, 2, 4, 8}, settings.msaa, direction)
			next.preset = .Custom
			apply_settings(next)
		}, rebuild = true},
	{label = "SHADOWS", value = proc() -> string {
			if !shadows_enabled() do return "OFF"
			return fmt.tprintf("%d x %d", settings.shadow_cascades, settings.shadow_resolution)
		}, step = proc(direction: int) {
			next := settings
			next.shadow_cascades = cycle([]u8{0, 1, 2, 3}, settings.shadow_cascades, direction)
			next.preset = .Custom
			apply_settings(next)
		}, rebuild = true},
	{label = "SHADOW DETAIL", value = proc() -> string {
			return fmt.tprintf("%d x %d taps", settings.shadow_resolution, settings.shadow_pcf)
		}, step = proc(direction: int) {
			next := settings
			next.shadow_resolution = cycle(
				[]u16{512, 1024, 2048, 4096},
				settings.shadow_resolution,
				direction,
			)
			next.shadow_pcf =
				next.shadow_resolution >= 2048 ? 9 : (next.shadow_resolution >= 1024 ? 4 : 1)
			next.preset = .Custom
			apply_settings(next)
		}, rebuild = true},
	{label = "TEXTURE FILTER", value = proc() -> string {
			return(
				settings.anisotropy <= 1 ? "TRILINEAR" : fmt.tprintf("%dx ANISO", settings.anisotropy) \
			)
		}, step = proc(direction: int) {
			next := settings
			next.anisotropy = cycle([]u8{1, 2, 4, 8, 16}, settings.anisotropy, direction)
			next.preset = .Custom
			apply_settings(next)
		}},
	{
		label = "VSYNC",
		value = proc() -> string {return settings.vsync ? "ON" : "OFF"},
		step = proc(direction: int) {
			next := settings
			next.vsync = direction > 0
			next.preset = .Custom
			apply_settings(next)
		},
		rebuild = true,
	},
	{label = "FRAME LIMIT", value = proc() -> string {
			return settings.fps_cap == 0 ? "OFF" : fmt.tprintf("%d FPS", settings.fps_cap)
		}, step = proc(direction: int) {
			next := settings
			next.fps_cap = cycle([]u32{0, 30, 60, 75, 120, 144, 240}, settings.fps_cap, direction)
			next.preset = .Custom
			apply_settings(next)
		}},
	{label = "GPU TIMING", value = proc() -> string {
			if !gpu_timer.supported do return "UNSUPPORTED"
			return settings.gpu_timing ? "ON" : "OFF"
		}, step = proc(direction: int) {
			next := settings
			next.gpu_timing = direction > 0
			apply_settings(next)
		}},
}

// TAB opens it; every function key is already spoken for by the debug tools.
update_settings_ui :: proc() {
	if key_pressed(glfw.KEY_TAB) {
		settings_ui.open = !settings_ui.open
		if settings_ui.open do grab_cursor(false)
	}
	if !settings_ui.open do return

	if key_pressed(glfw.KEY_ESCAPE) {
		settings_ui.open = false
		return
	}

	if key_pressed(glfw.KEY_UP) do settings_ui.row -= 1
	if key_pressed(glfw.KEY_DOWN) do settings_ui.row += 1
	settings_ui.row = clamp(settings_ui.row, 0, len(SETTING_ROWS) - 1)

	if key_pressed(glfw.KEY_LEFT) do SETTING_ROWS[settings_ui.row].step(-1)
	if key_pressed(glfw.KEY_RIGHT) do SETTING_ROWS[settings_ui.row].step(+1)
}

draw_settings_ui :: proc() {
	if !settings_ui.open do return

	scale := hud_scale()
	size := HUD_TEXT_SMALL * scale
	line := size + 12 * scale
	pad := 18 * scale

	width := f32(g.swapchain_extent.width)
	height := f32(g.swapchain_extent.height)

	value_column := f32(220) * scale
	panel_width := f32(520) * scale
	panel_height := line * f32(len(SETTING_ROWS) + 2) + 2 * pad

	x := (width - panel_width) * 0.5
	y := (height - panel_height) * 0.5

	hud_rect(x, y, panel_width, panel_height, HUD_PANEL, radius = 4 * scale)

	cursor := y + pad
	hud_text(x + pad, cursor, "SETTINGS", size, HUD_WARN)
	cursor += line * 1.5

	for row, i in SETTING_ROWS {
		selected := i == settings_ui.row
		if selected {
			hud_rect(
				x + pad * 0.5,
				cursor - 3 * scale,
				panel_width - pad,
				line,
				{0.20, 0.24, 0.30, 0.85},
				radius = 2 * scale,
			)
		}

		hud_text(x + pad, cursor, row.label, size, selected ? HUD_WHITE : HUD_DIM)
		hud_text(x + pad + value_column, cursor, row.value(), size, selected ? HUD_WHITE : HUD_DIM)

		// Flagged rather than hidden: knowing which rows cost a hitch is what
		// stops one from reading as a crash.
		if row.rebuild {
			hud_text(x + panel_width - pad - 40 * scale, cursor, "*", size, HUD_FAINT)
		}
		cursor += line
	}

	cursor += line * 0.5
	hud_text(
		x + pad,
		cursor,
		"ARROWS CHANGE   TAB CLOSE   * REBUILDS THE RENDERER",
		size * 0.85,
		HUD_FAINT,
	)
}
