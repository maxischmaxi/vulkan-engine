package main

import "core:log"
import "vendor:glfw"

Input :: struct {
	mouse_dx, mouse_dy: f64, // accumulated since the last consume, in raw units
	// Where the last motion event left the pointer. Lives here rather than in
	// the callback so that grabbing the cursor can break the chain: the position
	// jumps while the cursor is loose, and carrying that difference across the
	// grab would snap the view somewhere else the moment you click back in.
	last_x, last_y:     f64,
	have_last:          bool,
	cursor_grabbed:     bool,
	// A click that starts and ends between two frames is invisible to polling.
	// Latching the press means the shot still happens.
	fire_clicked:       bool,
	// The right button, latched the same way: the scope toggle.
	zoom_clicked:       bool,
	// Where the visible cursor is, in framebuffer pixels -- the space the HUD
	// draws in. Only meaningful while the cursor is loose; menus read this.
	cursor_x, cursor_y: f32,
	// Latched like fire_clicked, but regardless of grab state, so a menu click
	// between two frames is not lost either.
	click:              bool,
	// Edge detection. Both maps are snapshots taken once per frame rather than
	// sampled on demand: an earlier version updated prev_keys inside
	// key_pressed, so the second caller asking about the same key in one frame
	// always got false. Nothing hit that yet because every key had exactly one
	// caller, which is not a property that survives a growing codebase.
	keys:               map[i32]bool,
	prev_keys:          map[i32]bool,
}

input: Input

// Keys the game asks about. Polling a fixed list once per frame keeps
// key_pressed a pure lookup, so it can be called from anywhere, any number of
// times, and always answers the same thing within a frame.
WATCHED_KEYS := []i32 {
	glfw.KEY_W,
	glfw.KEY_A,
	glfw.KEY_S,
	glfw.KEY_D,
	glfw.KEY_SPACE,
	glfw.KEY_LEFT_SHIFT,
	glfw.KEY_LEFT_CONTROL,
	// the settings menu: open, navigate, change, close
	glfw.KEY_TAB,
	glfw.KEY_UP,
	glfw.KEY_DOWN,
	glfw.KEY_LEFT,
	glfw.KEY_RIGHT,
	glfw.KEY_C,
	glfw.KEY_V,
	glfw.KEY_R,
	glfw.KEY_T,
	glfw.KEY_E,
	glfw.KEY_ESCAPE,
	glfw.KEY_1,
	glfw.KEY_2,
	glfw.KEY_3,
	glfw.KEY_4,
	glfw.KEY_5,
	glfw.KEY_6,
	glfw.KEY_7,
	glfw.KEY_8,
	glfw.KEY_9,
	// the buy menu: open, back out
	glfw.KEY_B,
	glfw.KEY_0,
	glfw.KEY_F1,
	glfw.KEY_F2,
	glfw.KEY_F3,
	glfw.KEY_F4,
	glfw.KEY_F5,
	glfw.KEY_F6,
	glfw.KEY_F7,
	glfw.KEY_F8,
	glfw.KEY_F9,
	glfw.KEY_F10,
	glfw.KEY_F11,
	glfw.KEY_F12,
	glfw.KEY_GRAVE_ACCENT,
}

// Mouse deltas arrive through a callback rather than polling because several
// motion events can land within one frame; polling would drop all but the last.
init_input :: proc() {
	input.keys = make(map[i32]bool)
	input.prev_keys = make(map[i32]bool)

	glfw.SetCursorPosCallback(g.window, proc "c" (window: glfw.WindowHandle, x, y: f64) {
		context = g.odin_context
		if !input.cursor_grabbed do return

		if input.have_last {
			input.mouse_dx += x - input.last_x
			input.mouse_dy += y - input.last_y
		}
		input.last_x, input.last_y = x, y
		input.have_last = true
	})

	// Grabbing back after ESC is not decided here: whoever owns the current
	// screen (game vs menu) decides what a click means, in handle_hotkeys.
	glfw.SetMouseButtonCallback(
		g.window,
		proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
			context = g.odin_context
			if action != glfw.PRESS do return
			if button == glfw.MOUSE_BUTTON_RIGHT {
				// The scope toggle. Loose-cursor right clicks mean nothing.
				if input.cursor_grabbed do input.zoom_clicked = true
				return
			}
			if button != glfw.MOUSE_BUTTON_LEFT do return

			input.click = true
			// A shot needs the cursor: a loose-cursor click belongs to whatever
			// UI is up, never to the trigger.
			if input.cursor_grabbed do input.fire_clicked = true
		},
	)

	// Losing focus while grabbed leaves the compositor and the app disagreeing
	// about who owns the pointer.
	glfw.SetWindowFocusCallback(g.window, proc "c" (window: glfw.WindowHandle, focused: i32) {
		context = g.odin_context
		if focused == 0 && input.cursor_grabbed {
			grab_cursor(false)
		}
	})

	grab_cursor(true)
}

destroy_input :: proc() {
	delete(input.keys)
	delete(input.prev_keys)
}

// Snapshots the keyboard. Must run once per frame, before anything reads it.
poll_keys :: proc() {
	for key in WATCHED_KEYS {
		input.prev_keys[key] = input.keys[key]
		input.keys[key] = glfw.GetKey(g.window, key) == glfw.PRESS
	}
}

// Snapshots the visible cursor for menus. Polled rather than taken from the
// motion callback: the callback exists for deltas and deliberately ignores the
// loose cursor, and a menu does not care about sub-frame motion anyway.
poll_cursor :: proc() {
	if input.cursor_grabbed do return

	x, y := glfw.GetCursorPos(g.window)
	ww, wh := glfw.GetWindowSize(g.window)
	fw, fh := glfw.GetFramebufferSize(g.window)
	// Window and framebuffer size differ under a scaled compositor; the HUD
	// draws in framebuffer pixels, so the cursor converts to that space here.
	if ww > 0 && wh > 0 {
		input.cursor_x = f32(x) * f32(fw) / f32(ww)
		input.cursor_y = f32(y) * f32(fh) / f32(wh)
	}
}

grab_cursor :: proc(grab: bool) {
	input.cursor_grabbed = grab
	glfw.SetInputMode(g.window, glfw.CURSOR, grab ? glfw.CURSOR_DISABLED : glfw.CURSOR_NORMAL)

	// Raw motion skips the compositor's pointer acceleration, which is what an
	// aim-driven game wants. Only meaningful while the cursor is disabled.
	if glfw.RawMouseMotionSupported() {
		glfw.SetInputMode(g.window, glfw.RAW_MOUSE_MOTION, grab ? 1 : 0)
	}

	// A fresh grab restarts the delta chain, otherwise the first frame back
	// gets the jump from wherever the cursor was released. The click latch
	// resets too, so the click that changed the grab never leaks through.
	input.mouse_dx = 0
	input.mouse_dy = 0
	input.have_last = false
	input.fire_clicked = false
	input.zoom_clicked = false
	input.click = false
}

key_down :: proc(key: i32) -> bool {
	return input.keys[key]
}

// True only on the frame the key goes down. Pure lookup, so calling it twice in
// one frame gives the same answer twice.
key_pressed :: proc(key: i32) -> bool {
	return input.keys[key] && !input.prev_keys[key]
}

consume_mouse_delta :: proc() -> (dx, dy: f32) {
	dx = f32(input.mouse_dx)
	dy = f32(input.mouse_dy)
	input.mouse_dx = 0
	input.mouse_dy = 0
	return
}

// True if the left button went down since the last call, however briefly.
consume_fire_click :: proc() -> bool {
	clicked := input.fire_clicked
	input.fire_clicked = false
	return clicked
}

// The right button's latch: the scope toggle.
consume_zoom_click :: proc() -> bool {
	clicked := input.zoom_clicked
	input.zoom_clicked = false
	return clicked
}

// The menu counterpart of consume_fire_click: any left press, any grab state.
consume_click :: proc() -> bool {
	clicked := input.click
	input.click = false
	return clicked
}

log_input_support :: proc() {
	if glfw.RawMouseMotionSupported() {
		log.info("Input: raw mouse motion")
	} else {
		log.warn("Input: raw mouse motion unsupported, using accelerated deltas")
	}
}
