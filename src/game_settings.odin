package main

import "vendor:glfw"

// The player-facing settings that are not render quality: mouse, view, HUD
// and display. These are the single source of truth -- camera and tonemap
// read them directly every frame, so every change is live.

Game_Settings :: struct {
	sensitivity:      f32, // counter-strike scale, 0.1 .. 8
	zoom_sensitivity: f32, // extra multiplier while scoped, 0.5 .. 2
	invert_y:         bool,
	fov:              f32, // horizontal base at 16:9, 70 .. 110; scoping narrows from here
	hud_scale:        f32, // multiplier on the resolution-derived scale, 0.8 .. 1.2
	brightness:       f32, // the tonemap exposure, 0.5 .. 2
}

game_settings := Game_Settings {
	sensitivity      = 2,
	zoom_sensitivity = 1,
	fov              = 90,
	hud_scale        = 1,
	brightness       = 1,
}

clamp_game_settings :: proc(s: Game_Settings) -> Game_Settings {
	out := s
	out.sensitivity = clamp(out.sensitivity, 0.1, 8)
	out.zoom_sensitivity = clamp(out.zoom_sensitivity, 0.5, 2)
	out.fov = clamp(out.fov, 70, 110)
	out.hud_scale = clamp(out.hud_scale, 0.8, 1.2)
	out.brightness = clamp(out.brightness, 0.5, 2)
	return out
}

clamp_crosshair_style :: proc(s: Crosshair_Style) -> Crosshair_Style {
	out := s
	out.size = clamp(out.size, 0.5, 10)
	out.thickness = clamp(out.thickness, 0.5, 3)
	out.gap = clamp(out.gap, 0, 8)
	out.outline = clamp(out.outline, 0, 2)
	out.color.r = clamp(out.color.r, 0, 1)
	out.color.g = clamp(out.color.g, 0, 1)
	out.color.b = clamp(out.color.b, 0, 1)
	out.color.a = 1
	return out
}

// On Wayland there is no exclusive mode switch: fullscreen maps to the
// compositor's xdg fullscreen at the current video mode, which is exactly the
// borderless behaviour wanted. Offering only Windowed/Fullscreen is honest.
Window_Mode :: enum u8 {
	Windowed,
	Fullscreen,
}

Window_Settings :: struct {
	mode:   Window_Mode,
	width:  i32, // the windowed size; fullscreen uses the monitor's mode
	height: i32,
}

window_settings := Window_Settings {
	mode   = .Windowed,
	width  = 1600,
	height = 900,
}

clamp_window_settings :: proc(s: Window_Settings) -> Window_Settings {
	out := s
	if out.width < 640 do out.width = 1600
	if out.height < 360 do out.height = 900
	return out
}

// The runtime toggle. No swapchain work here: the resize callback fires and
// the existing framebuffer_resized path rebuilds everything, the same way a
// window drag does. A tiling compositor may refuse the windowed size -- the
// settings row shows the actual extent next to the request for that reason.
apply_window_settings :: proc(next: Window_Settings) {
	window_settings = clamp_window_settings(next)

	monitor := glfw.GetPrimaryMonitor()
	if window_settings.mode == .Fullscreen && monitor != nil {
		vm := glfw.GetVideoMode(monitor)
		glfw.SetWindowMonitor(g.window, monitor, 0, 0, vm.width, vm.height, vm.refresh_rate)
	} else if glfw.GetWindowMonitor(g.window) != nil {
		// position args are ignored on Wayland; any values do
		glfw.SetWindowMonitor(
			g.window,
			nil,
			100,
			100,
			window_settings.width,
			window_settings.height,
			0,
		)
	} else {
		glfw.SetWindowSize(g.window, window_settings.width, window_settings.height)
	}
	save_settings()
}
