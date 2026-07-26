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
	glfw.KEY_C,
	glfw.KEY_V,
	glfw.KEY_R,
	glfw.KEY_ESCAPE,
	glfw.KEY_1,
	glfw.KEY_2,
	glfw.KEY_3,
	glfw.KEY_4,
	glfw.KEY_F1,
	glfw.KEY_F2,
	glfw.KEY_F3,
	glfw.KEY_F4,
	glfw.KEY_F5,
	glfw.KEY_F6,
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

	// Clicking back into the window re-grabs after ESC released the cursor.
	glfw.SetMouseButtonCallback(
		g.window,
		proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
			context = g.odin_context
			if action != glfw.PRESS do return

			// The click that takes the cursor back is not a shot.
			if !input.cursor_grabbed {
				grab_cursor(true)
				return
			}
			if button == glfw.MOUSE_BUTTON_LEFT do input.fire_clicked = true
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

grab_cursor :: proc(grab: bool) {
	input.cursor_grabbed = grab
	glfw.SetInputMode(g.window, glfw.CURSOR, grab ? glfw.CURSOR_DISABLED : glfw.CURSOR_NORMAL)

	// Raw motion skips the compositor's pointer acceleration, which is what an
	// aim-driven game wants. Only meaningful while the cursor is disabled.
	if glfw.RawMouseMotionSupported() {
		glfw.SetInputMode(g.window, glfw.RAW_MOUSE_MOTION, grab ? 1 : 0)
	}

	// A fresh grab restarts the delta chain, otherwise the first frame back
	// gets the jump from wherever the cursor was released.
	input.mouse_dx = 0
	input.mouse_dy = 0
	input.have_last = false
	input.fire_clicked = false
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

log_input_support :: proc() {
	if glfw.RawMouseMotionSupported() {
		log.info("Input: raw mouse motion")
	} else {
		log.warn("Input: raw mouse motion unsupported, using accelerated deltas")
	}
}
