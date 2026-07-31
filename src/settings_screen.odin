package main

import "core:fmt"
import "core:math"
import "vendor:glfw"

// The settings screen: every tunable in the game behind one tabbed panel,
// reachable from the main menu and the pause overlay. Mouse and keyboard
// share one focus -- hovering moves it, arrows move it -- so neither input
// model is a second-class citizen.
//
// Table-driven like the old TAB panel it replaces: a setting cannot be added
// and quietly stay invisible, because these tables are what draws them.

Settings_Tab :: enum u8 {
	Video,
	Audio,
	Game,
	Crosshair,
}

@(private = "file")
TAB_NAMES := []string{"VIDEO", "AUDIO", "GAME", "CROSSHAIR"}

Row_Kind :: enum u8 {
	Header,
	Cycler, // value() + step(): toggles are two-value cyclers
	Slider, // get() + set(): applied live, saved debounced
}

Settings_Row :: struct {
	label:        string,
	kind:         Row_Kind,
	value:        proc() -> string, // temp allocator, frame lifetime
	step:         proc(direction: int),
	get:          proc() -> f32,
	set:          proc(v: f32),
	lo, hi, snap: f32,
	fmt_str:      string,
	// Shown as * so the cost of a renderer rebuild is visible before it is
	// paid rather than felt as a stutter afterwards.
	rebuild:      bool,
	enabled:      proc() -> bool, // nil = always
}

Settings_Screen :: struct {
	open:           bool,
	tab:            Settings_Tab,
	focus:          int,
	dirty:          bool, // a live change awaits its debounced save
	last_cx, last_cy: f32, // hover only steals focus when the mouse moved
}

settings_screen: Settings_Screen

// Cycles `current` through `values`, clamping at both ends rather than
// wrapping: holding a direction should come to rest on the extreme.
@(private = "file")
cycle :: proc(values: []$T, current: T, direction: int) -> T {
	index := 0
	for v, i in values {
		if v == current do index = i
	}
	return values[clamp(index + direction, 0, len(values) - 1)]
}

// ---------------------------------------------------------------------- rows

@(private = "file")
VIDEO_ROWS := []Settings_Row {
	{label = "DISPLAY", kind = .Header},
	{
		label = "WINDOW MODE",
		kind = .Cycler,
		value = proc() -> string {
			return window_settings.mode == .Fullscreen ? "FULLSCREEN" : "WINDOWED"
		},
		step = proc(direction: int) {
			next := window_settings
			next.mode = direction > 0 ? .Fullscreen : .Windowed
			apply_window_settings(next)
		},
	},
	{
		label = "RESOLUTION",
		kind = .Cycler,
		value = proc() -> string {
			// A tiling compositor may refuse the request; showing the actual
			// extent keeps a refused resize visible rather than mysterious.
			if i32(g.swapchain_extent.width) != window_settings.width ||
			   i32(g.swapchain_extent.height) != window_settings.height {
				return fmt.tprintf(
					"%dx%d (IS %dx%d)",
					window_settings.width,
					window_settings.height,
					g.swapchain_extent.width,
					g.swapchain_extent.height,
				)
			}
			return fmt.tprintf("%dx%d", window_settings.width, window_settings.height)
		},
		step = proc(direction: int) {
			sizes := [][2]i32 {
				{1280, 720},
				{1600, 900},
				{1920, 1080},
				{2560, 1440},
				{3440, 1440},
				{3840, 2160},
			}
			index := 0
			for s, i in sizes {
				if s.x == window_settings.width && s.y == window_settings.height do index = i
			}
			next := window_settings
			pick := sizes[clamp(index + direction, 0, len(sizes) - 1)]
			next.width, next.height = pick.x, pick.y
			apply_window_settings(next)
		},
		enabled = proc() -> bool {return window_settings.mode == .Windowed},
	},
	{
		label = "VSYNC",
		kind = .Cycler,
		value = proc() -> string {return settings.vsync ? "ON" : "OFF"},
		step = proc(direction: int) {
			next := settings
			next.vsync = direction > 0
			apply_settings(next)
		},
		rebuild = true,
	},
	{
		label = "FRAME LIMIT",
		kind = .Cycler,
		value = proc() -> string {
			return settings.fps_cap == 0 ? "OFF" : fmt.tprintf("%d FPS", settings.fps_cap)
		},
		step = proc(direction: int) {
			next := settings
			next.fps_cap = cycle(
				[]u32{0, 30, 60, 75, 120, 144, 165, 240, 360},
				settings.fps_cap,
				direction,
			)
			apply_settings(next)
		},
	},
	{
		label = "BRIGHTNESS",
		kind = .Slider,
		get = proc() -> f32 {return game_settings.brightness},
		set = proc(v: f32) {game_settings.brightness = v},
		lo = 0.5,
		hi = 2.0,
		snap = 0.05,
		fmt_str = "%.2f",
	},
	{label = "QUALITY", kind = .Header},
	{
		label = "PRESET",
		kind = .Cycler,
		value = proc() -> string {return fmt.tprint(settings.preset)},
		step = proc(direction: int) {
			order := []Preset{.Potato, .Low, .Medium, .High, .Ultra}
			next := cycle(order, settings.preset, direction)
			// Custom is not in the list, so a hand-tuned config steps to the
			// nearest end rather than staying stuck.
			if settings.preset == .Custom do next = direction > 0 ? .Medium : .Low
			applied := PRESETS[next]
			// presets carry no fps_cap opinion; keep the player's
			applied.fps_cap = settings.fps_cap
			applied.gpu_timing = settings.gpu_timing
			apply_settings(applied)
		},
		rebuild = true,
	},
	{
		label = "RENDER SCALE",
		kind = .Cycler,
		value = proc() -> string {
			extent := scene_extent()
			return fmt.tprintf(
				"%d%%  %dx%d",
				int(settings.render_scale * 100 + 0.5),
				extent.width,
				extent.height,
			)
		},
		step = proc(direction: int) {
			next := settings
			next.render_scale = cycle(
				[]f32{0.5, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9, 1.0},
				settings.render_scale,
				direction,
			)
			next.preset = .Custom
			apply_settings(next)
		},
		rebuild = true,
	},
	{
		label = "ANTI-ALIASING",
		kind = .Cycler,
		value = proc() -> string {
			return settings.msaa <= 1 ? "OFF" : fmt.tprintf("%dx MSAA", settings.msaa)
		},
		step = proc(direction: int) {
			next := settings
			next.msaa = cycle([]u8{1, 2, 4, 8}, settings.msaa, direction)
			next.preset = .Custom
			apply_settings(next)
		},
		rebuild = true,
	},
	{
		label = "SHADOWS",
		kind = .Cycler,
		value = proc() -> string {
			if !shadows_enabled() do return "OFF"
			return fmt.tprintf("%d CASCADES", settings.shadow_cascades)
		},
		step = proc(direction: int) {
			next := settings
			next.shadow_cascades = cycle([]u8{0, 1, 2, 3}, settings.shadow_cascades, direction)
			next.preset = .Custom
			apply_settings(next)
		},
		rebuild = true,
	},
	{
		label = "SHADOW DETAIL",
		kind = .Cycler,
		value = proc() -> string {
			return fmt.tprintf("%d x %d TAPS", settings.shadow_resolution, settings.shadow_pcf)
		},
		step = proc(direction: int) {
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
		},
		rebuild = true,
	},
	{
		label = "TEXTURE FILTER",
		kind = .Cycler,
		value = proc() -> string {
			return(
				settings.anisotropy <= 1 \
				? "TRILINEAR" \
				: fmt.tprintf("%dx ANISO", settings.anisotropy) \
			)
		},
		step = proc(direction: int) {
			next := settings
			next.anisotropy = cycle([]u8{1, 2, 4, 8, 16}, settings.anisotropy, direction)
			next.preset = .Custom
			apply_settings(next)
		},
	},
	{
		label = "TEXTURE SHARPNESS",
		kind = .Cycler,
		value = proc() -> string {
			return(
				settings.mip_lod_bias == 0 \
				? "SHARP" \
				: fmt.tprintf("SOFT %.1f", settings.mip_lod_bias) \
			)
		},
		step = proc(direction: int) {
			next := settings
			// inverted: stepping right means sharper, and sharper is less bias
			next.mip_lod_bias = cycle([]f32{2, 1, 0.5, 0}, settings.mip_lod_bias, direction)
			next.preset = .Custom
			apply_settings(next)
		},
	},
	{
		label = "GPU TIMING",
		kind = .Cycler,
		value = proc() -> string {
			if !gpu_timer.supported do return "UNSUPPORTED"
			return settings.gpu_timing ? "ON" : "OFF"
		},
		step = proc(direction: int) {
			next := settings
			next.gpu_timing = direction > 0
			apply_settings(next)
		},
		enabled = proc() -> bool {return gpu_timer.supported},
	},
}

@(private = "file")
volume_slider :: proc(get: proc() -> f32, set: proc(v: f32)) -> Settings_Row {
	return {kind = .Slider, get = get, set = set, lo = 0, hi = 100, snap = 5, fmt_str = "%.0f%%"}
}

@(private = "file")
AUDIO_ROWS := []Settings_Row {
	{label = "VOLUME", kind = .Header},
	{
		label = "MASTER",
		kind = .Slider,
		get = proc() -> f32 {return audio_settings.master * 100},
		set = proc(v: f32) {audio_settings.master = v / 100;audio_apply_volumes()},
		lo = 0,
		hi = 100,
		snap = 5,
		fmt_str = "%.0f%%",
	},
	{
		label = "MUSIC",
		kind = .Slider,
		get = proc() -> f32 {return audio_settings.music * 100},
		set = proc(v: f32) {audio_settings.music = v / 100;audio_apply_volumes()},
		lo = 0,
		hi = 100,
		snap = 5,
		fmt_str = "%.0f%%",
	},
	{
		label = "EFFECTS",
		kind = .Slider,
		get = proc() -> f32 {return audio_settings.effects * 100},
		set = proc(v: f32) {audio_settings.effects = v / 100;audio_apply_volumes()},
		lo = 0,
		hi = 100,
		snap = 5,
		fmt_str = "%.0f%%",
	},
	{
		label = "AMBIENT",
		kind = .Slider,
		get = proc() -> f32 {return audio_settings.ambient * 100},
		set = proc(v: f32) {audio_settings.ambient = v / 100;audio_apply_volumes()},
		lo = 0,
		hi = 100,
		snap = 5,
		fmt_str = "%.0f%%",
	},
}

@(private = "file")
GAME_ROWS := []Settings_Row {
	{label = "MOUSE", kind = .Header},
	{
		label = "SENSITIVITY",
		kind = .Slider,
		get = proc() -> f32 {return game_settings.sensitivity},
		set = proc(v: f32) {game_settings.sensitivity = v},
		lo = 0.1,
		hi = 8,
		snap = 0.05,
		fmt_str = "%.2f",
	},
	{
		label = "ZOOM SENSITIVITY",
		kind = .Slider,
		get = proc() -> f32 {return game_settings.zoom_sensitivity},
		set = proc(v: f32) {game_settings.zoom_sensitivity = v},
		lo = 0.5,
		hi = 2,
		snap = 0.05,
		fmt_str = "%.2f",
	},
	{
		label = "INVERT Y",
		kind = .Cycler,
		value = proc() -> string {return game_settings.invert_y ? "ON" : "OFF"},
		step = proc(direction: int) {game_settings.invert_y = direction > 0},
	},
	{label = "VIEW", kind = .Header},
	{
		label = "FIELD OF VIEW",
		kind = .Slider,
		get = proc() -> f32 {return game_settings.fov},
		set = proc(v: f32) {
			game_settings.fov = v
			if !weapon_state.zoom_active do camera.fov_horizontal = v
		},
		lo = 70,
		hi = 110,
		snap = 1,
		fmt_str = "%.0f",
	},
	{
		label = "HUD SCALE",
		kind = .Slider,
		get = proc() -> f32 {return game_settings.hud_scale},
		set = proc(v: f32) {game_settings.hud_scale = v},
		lo = 0.8,
		hi = 1.2,
		snap = 0.05,
		fmt_str = "%.2f",
	},
}

@(private = "file")
Crosshair_Color :: struct {
	name:  string,
	color: [3]f32, // linear, like every HUD colour
}

@(private = "file")
CROSSHAIR_COLORS := []Crosshair_Color {
	{"GREEN", {0.35, 1.0, 0.42}},
	{"YELLOW", {1.0, 0.82, 0.07}},
	{"CYAN", {0.07, 0.87, 0.82}},
	{"MAGENTA", {0.87, 0.07, 0.82}},
	{"WHITE", {1, 1, 1}},
	{"ORANGE", {1.0, 0.38, 0.07}},
}

@(private = "file")
crosshair_color_index :: proc() -> int {
	for preset, i in CROSSHAIR_COLORS {
		if math.abs(crosshair.color.r - preset.color.r) < 0.01 &&
		   math.abs(crosshair.color.g - preset.color.g) < 0.01 &&
		   math.abs(crosshair.color.b - preset.color.b) < 0.01 {
			return i
		}
	}
	return -1
}

@(private = "file")
CROSSHAIR_ROWS := []Settings_Row {
	{label = "STYLE", kind = .Header},
	{
		label = "COLOR",
		kind = .Cycler,
		value = proc() -> string {
			index := crosshair_color_index()
			return index >= 0 ? CROSSHAIR_COLORS[index].name : "CUSTOM"
		},
		step = proc(direction: int) {
			index := crosshair_color_index()
			// from CUSTOM, either direction lands on the first preset
			next := index < 0 ? 0 : clamp(index + direction, 0, len(CROSSHAIR_COLORS) - 1)
			c := CROSSHAIR_COLORS[next].color
			crosshair.color = {c.r, c.g, c.b, 1}
		},
	},
	{
		label = "SIZE",
		kind = .Slider,
		get = proc() -> f32 {return crosshair.size},
		set = proc(v: f32) {crosshair.size = v},
		lo = 0.5,
		hi = 10,
		snap = 0.5,
		fmt_str = "%.1f",
	},
	{
		label = "THICKNESS",
		kind = .Slider,
		get = proc() -> f32 {return crosshair.thickness},
		set = proc(v: f32) {crosshair.thickness = v},
		lo = 0.5,
		hi = 3,
		snap = 0.5,
		fmt_str = "%.1f",
	},
	{
		label = "GAP",
		kind = .Slider,
		get = proc() -> f32 {return crosshair.gap},
		set = proc(v: f32) {crosshair.gap = v},
		lo = 0,
		hi = 8,
		snap = 0.5,
		fmt_str = "%.1f",
	},
	{
		label = "OUTLINE",
		kind = .Slider,
		get = proc() -> f32 {return crosshair.outline},
		set = proc(v: f32) {crosshair.outline = v},
		lo = 0,
		hi = 2,
		snap = 0.5,
		fmt_str = "%.1f",
	},
	{
		label = "CENTER DOT",
		kind = .Cycler,
		value = proc() -> string {return crosshair.dot ? "ON" : "OFF"},
		step = proc(direction: int) {crosshair.dot = direction > 0},
	},
	{
		label = "T-STYLE",
		kind = .Cycler,
		value = proc() -> string {return crosshair.t_style ? "ON" : "OFF"},
		step = proc(direction: int) {crosshair.t_style = direction > 0},
	},
}

@(private = "file")
tab_rows :: proc(tab: Settings_Tab) -> []Settings_Row {
	switch tab {
	case .Video:
		return VIDEO_ROWS
	case .Audio:
		return AUDIO_ROWS
	case .Game:
		return GAME_ROWS
	case .Crosshair:
		return CROSSHAIR_ROWS
	}
	return nil
}

// -------------------------------------------------------------------- logic

open_settings_screen :: proc(tab := Settings_Tab.Video) {
	settings_screen.open = true
	settings_screen.tab = tab
	settings_screen.focus = first_row(tab_rows(tab))
}

close_settings_screen :: proc() {
	settings_screen.open = false
	if settings_screen.dirty {
		settings_screen.dirty = false
		save_settings()
	}
}

@(private = "file")
first_row :: proc(rows: []Settings_Row) -> int {
	for row, i in rows {
		if row.kind != .Header do return i
	}
	return 0
}

@(private = "file")
row_selectable :: proc(row: Settings_Row) -> bool {
	if row.kind == .Header do return false
	return row.enabled == nil || row.enabled()
}

@(private = "file")
move_focus :: proc(rows: []Settings_Row, direction: int) {
	next := settings_screen.focus
	for _ in 0 ..< len(rows) {
		next = clamp(next + direction, 0, len(rows) - 1)
		if row_selectable(rows[next]) {
			settings_screen.focus = next
			return
		}
		if next == 0 || next == len(rows) - 1 do return
	}
}

update_settings_screen :: proc() {
	if !settings_screen.open do return

	if key_pressed(glfw.KEY_ESCAPE) {
		close_settings_screen()
		return
	}

	rows := tab_rows(settings_screen.tab)
	if key_pressed(glfw.KEY_UP) do move_focus(rows, -1)
	if key_pressed(glfw.KEY_DOWN) do move_focus(rows, +1)

	// Q/E flip tabs from the keyboard without stealing the arrows the focused
	// row wants. (LEFT/RIGHT belong to the row's widget.)
	if key_pressed(glfw.KEY_Q) || key_pressed(glfw.KEY_E) {
		delta := key_pressed(glfw.KEY_E) ? 1 : -1
		next := clamp(int(settings_screen.tab) + delta, 0, len(Settings_Tab) - 1)
		if next != int(settings_screen.tab) {
			settings_screen.tab = Settings_Tab(next)
			settings_screen.focus = first_row(tab_rows(settings_screen.tab))
		}
	}

	// The debounce: a slider drag writes the file once, when it ends.
	if settings_screen.dirty && !ui_drag_active() {
		settings_screen.dirty = false
		save_settings()
	}
}

// --------------------------------------------------------------------- draw

draw_settings_screen :: proc() {
	if !settings_screen.open do return

	scale := hud_scale()
	width := f32(g.swapchain_extent.width)
	height := f32(g.swapchain_extent.height)

	hud_rect(0, 0, width, height, UI_SCRIM_HEAVY)

	panel_w := min(880 * scale, width - 48 * scale)
	panel_h := min(840 * scale, height - 48 * scale)
	px := math.round((width - panel_w) * 0.5)
	py := math.round((height - panel_h) * 0.5)
	pad := 32 * scale

	ui_panel(px, py, panel_w, panel_h)
	ui_heading(px + pad, py + 24 * scale, "SETTINGS", UI_H2 * scale)

	tab_i := int(settings_screen.tab)
	if ui_tab_bar(px + pad, py + 84 * scale, panel_w - 2 * pad, 40 * scale, TAB_NAMES, &tab_i) {
		settings_screen.tab = Settings_Tab(tab_i)
		settings_screen.focus = first_row(tab_rows(settings_screen.tab))
	}

	// hover moves focus only while the mouse moves, so arrows are not fought
	// by a resting cursor
	mouse_moved :=
		input.cursor_x != settings_screen.last_cx || input.cursor_y != settings_screen.last_cy
	settings_screen.last_cx = input.cursor_x
	settings_screen.last_cy = input.cursor_y

	rows := tab_rows(settings_screen.tab)
	list := Ui_List {
		x     = px + pad,
		y     = py + 136 * scale,
		w     = panel_w - 2 * pad,
		row_h = 36 * scale,
		gap   = 3 * scale,
	}
	// the crosshair tab gives the right half to the live preview
	if settings_screen.tab == .Crosshair do list.w = (panel_w - 2 * pad) * 0.55

	for row, i in rows {
		rx, ry, rw, rh := ui_list_row(&list)
		enabled := row.enabled == nil || row.enabled()

		if row.kind != .Header && enabled && mouse_moved && cursor_in(rx, ry, rw, rh) {
			settings_screen.focus = i
		}
		focused := settings_screen.focus == i

		switch row.kind {
		case .Header:
			size := hud_font_size(UI_LABEL * scale)
			ui_heading(rx, ry + rh - size - 2 * scale, row.label, size, UI_TEXT_FAINT)

		case .Cycler:
			if enabled {
				delta := ui_cycler(rx, ry, rw, rh, row.label, row.value(), focused, 100 + i)
				if delta != 0 {
					row.step(delta)
					settings_screen.dirty = true
				}
			} else {
				size := hud_font_size(UI_LABEL * scale)
				ty := ry + (rh - size) * 0.5
				hud_text(rx + UI_PAD * scale, ty, row.label, size, UI_TEXT_FAINT)
				hud_text(rx + rw - UI_PAD * scale, ty, row.value(), size, UI_TEXT_FAINT, .Right)
			}

		case .Slider:
			v := row.get()
			if ui_slider(rx, ry, rw, rh, row.label, &v, row.lo, row.hi, row.fmt_str, row.snap, focused, 100 + i) {
				row.set(v)
				settings_screen.dirty = true
			}
		}

		if row.rebuild {
			hud_text(rx - 14 * scale, ry + (rh - UI_LABEL * scale) * 0.5, "*", UI_LABEL * scale, UI_TEXT_FAINT)
		}
	}

	if settings_screen.tab == .Crosshair {
		draw_crosshair_tab_preview(px, py, panel_w, panel_h, pad, scale)
	}

	hud_text(
		px + pad,
		py + panel_h - 36 * scale,
		"ARROWS CHANGE   Q E SWITCH TAB   ESC CLOSE   * REBUILDS THE RENDERER",
		hud_font_size(UI_MICRO * scale),
		UI_TEXT_FAINT,
	)

	// a click that hit no widget dies here, the menus' rule
	_ = consume_click()
}

// A split light/dark backdrop, so the crosshair proves itself against both
// the bright sandstone and the shadowed corners it has to survive over.
@(private = "file")
draw_crosshair_tab_preview :: proc(px, py, panel_w, panel_h, pad, scale: f32) {
	w := (panel_w - 2 * pad) * 0.38
	h := 240 * scale
	x := px + panel_w - pad - w
	y := py + 150 * scale

	hud_rect(x, y, w * 0.5, h, {0.60, 0.53, 0.42, 1}) // sandstone-ish
	hud_rect(x + w * 0.5, y, w * 0.5, h, {0.015, 0.02, 0.03, 1}) // shadow
	hud_frame(x, y, w, h, UI_STROKE_W * scale, UI_STROKE)

	draw_crosshair_preview(x + w * 0.25, y + h * 0.5)
	draw_crosshair_preview(x + w * 0.75, y + h * 0.5)
}
