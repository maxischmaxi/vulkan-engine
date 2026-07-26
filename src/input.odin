package main

import "core:log"
import "vendor:glfw"

Input :: struct {
	mouse_dx, mouse_dy: f64, // accumulated since the last consume, in raw units
	cursor_grabbed:     bool,
	prev_keys:          map[i32]bool, // for edge detection on toggles
}

input: Input

// Mouse deltas arrive through a callback rather than polling because several
// motion events can land within one frame; polling would drop all but the last.
init_input :: proc() {
	input.prev_keys = make(map[i32]bool)

	glfw.SetCursorPosCallback(g.window, proc "c" (window: glfw.WindowHandle, x, y: f64) {
		context = g.odin_context
		if !input.cursor_grabbed do return

		@(static) last_x, last_y: f64
		@(static) have_last: bool

		if have_last {
			input.mouse_dx += x - last_x
			input.mouse_dy += y - last_y
		}
		last_x, last_y = x, y
		have_last = true
	})

	// Clicking back into the window re-grabs after ESC released the cursor.
	glfw.SetMouseButtonCallback(
		g.window,
		proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
			context = g.odin_context
			if action == glfw.PRESS && !input.cursor_grabbed {
				grab_cursor(true)
			}
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
	delete(input.prev_keys)
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
}

key_down :: proc(key: i32) -> bool {
	return glfw.GetKey(g.window, key) == glfw.PRESS
}

// True only on the frame the key goes down.
key_pressed :: proc(key: i32) -> bool {
	down := key_down(key)
	was := input.prev_keys[key]
	input.prev_keys[key] = down
	return down && !was
}

consume_mouse_delta :: proc() -> (dx, dy: f32) {
	dx = f32(input.mouse_dx)
	dy = f32(input.mouse_dy)
	input.mouse_dx = 0
	input.mouse_dy = 0
	return
}

log_input_support :: proc() {
	if glfw.RawMouseMotionSupported() {
		log.info("Input: raw mouse motion")
	} else {
		log.warn("Input: raw mouse motion unsupported, using accelerated deltas")
	}
}
