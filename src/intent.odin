package main

import "game"
import "vendor:glfw"

// Turns the keyboard and the camera into the Pawn_Input the shared simulation
// eats. Edge-triggered keys are latched between frames: a key pressed and
// released inside one frame still has to reach the simulation, which polling
// at tick time would miss.

// Every edge-triggered key MUST latch here rather than being read with
// key_pressed at tick time: most frames run zero ticks (165 fps against a
// 64 Hz accumulator), and an edge read inside the tick loop simply evaporates
// on a tickless frame. The reload that needed two presses was exactly this.
Intent :: struct {
	jump_pressed:  bool, // each latched until the first tick consumes it
	fire_pressed:  bool,
	reload:        bool,
	slot_change:   bool,
	slot:          i8,
	toggle_noclip: bool,
}

intent: Intent

// Called once per frame while the cursor is grabbed, before the tick loop.
//
// The fire latch is PEEKED, not consumed: the cosmetic weapon path consumes
// input.fire_clicked after the tick loop, and both it and the wire need to see
// the same click.
gather_player_intent :: proc() {
	if key_pressed(glfw.KEY_V) do intent.toggle_noclip = true
	if key_pressed(glfw.KEY_SPACE) do intent.jump_pressed = true
	if input.fire_clicked do intent.fire_pressed = true
	if key_pressed(glfw.KEY_R) do intent.reload = true
	// The scope toggles here, at frame rate: waiting for a tick would add a
	// perceptible stutter to the lens.
	if consume_zoom_click() do weapon_toggle_zoom()
	for key, slot in SLOT_KEYS {
		if key_pressed(key) {
			intent.slot_change = true
			intent.slot = i8(slot)
		}
	}
}

// Sampled at tick time. Held keys are read fresh so every tick in a frame sees
// them; the jump edge fires once and the pawn's own buffer carries it on.
build_local_input :: proc() -> game.Pawn_Input {
	input_: game.Pawn_Input
	input_.yaw = camera.yaw
	input_.pitch = camera.pitch
	input_.weapon_slot = -1

	// A loose cursor means a menu owns the keyboard -- the pause overlay, the
	// settings. The pawn stands still instead of ghost-walking through it.
	if !input.cursor_grabbed && !bench_active() do return input_

	if key_down(glfw.KEY_W) do input_.buttons += {.Forward}
	if key_down(glfw.KEY_S) do input_.buttons += {.Back}
	if key_down(glfw.KEY_D) do input_.buttons += {.Right}
	if key_down(glfw.KEY_A) do input_.buttons += {.Left}
	if key_down(glfw.KEY_SPACE) do input_.buttons += {.Jump}
	if key_down(glfw.KEY_LEFT_CONTROL) do input_.buttons += {.Crouch}
	if key_down(glfw.KEY_LEFT_SHIFT) do input_.buttons += {.Slow}

	// Noclip kept its old down-key; mapping C to crouch outside noclip would
	// hand the stance a second key nobody asked for.
	if player.noclip && key_down(glfw.KEY_C) do input_.buttons += {.Crouch}

	// The trigger goes on the wire too: the server's fire control is the one
	// that deals damage, and it can only fire what it is told. Held state may
	// be read fresh -- it spans frames on its own.
	//
	// It goes on the wire only where the rules allow it. The server asks the
	// same rule and would refuse the shot regardless, so this changes nothing
	// about what happens -- it is what makes a refusal on the server side mean
	// "this client is not the one we shipped" instead of "this is a countdown".
	may_fire := local_fire_block() == .None

	if may_fire && glfw.GetMouseButton(g.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS {
		input_.buttons += {.Fire}
	}
	// Scoped in walks slower, and only the wire can make the server agree.
	if weapon_state.zoom_active {
		input_.buttons += {.Zoom}
	}

	if intent.jump_pressed {
		intent.jump_pressed = false
		input_.buttons += {.Jump_Pressed}
	}
	// Both latches clear either way. Holding a click back until the match goes
	// live would fire it on the very first live tick, which is the countdown
	// shot arriving late rather than not at all.
	if intent.fire_pressed {
		intent.fire_pressed = false
		if may_fire do input_.buttons += {.Fire_Pressed}
	}
	if intent.reload {
		intent.reload = false
		if may_fire do input_.buttons += {.Reload}
	}
	if intent.slot_change {
		intent.slot_change = false
		input_.weapon_slot = intent.slot
	}
	return input_
}
