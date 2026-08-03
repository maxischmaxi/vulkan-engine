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
	jump_pressed:   bool, // each latched until the first tick consumes it
	fire_pressed:   bool,
	reload:         bool,
	// What the player asked to hold, as a hand.odin select code. The flag
	// beside it rather than a sentinel: 0 is a legal code (the primary slot),
	// so a zeroed Intent cannot be allowed to read as a request for it.
	select_change:  bool,
	select:         i8,
	toggle_noclip:  bool,
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

	// Holstering happens here too, and at frame rate for the same reason: the
	// hands move now and the wire is told afterwards (hand_view.odin). Both the
	// keys and the wheel come out as one select code, so the tick below has one
	// thing to send whichever way it was asked for.
	for key, slot in SLOT_KEYS {
		if !key_pressed(key) do continue
		if code := hand_key(slot); code >= 0 {
			intent.select_change = true
			intent.select = code
		}
	}
	if steps := consume_scroll(); steps != 0 {
		if code := hand_scroll(steps); code >= 0 {
			intent.select_change = true
			intent.select = code
		}
	}
}

// Sampled at tick time. Held keys are read fresh so every tick in a frame sees
// them; the jump edge fires once and the pawn's own buffer carries it on.
//
// Every command that leaves here is also shown to hand_note_command, which is
// how the client counts the same wind-up ticks the server will count off the
// very same commands. Both prediction and the offline path come through here,
// so there is exactly one place that has to be right.
build_local_input :: proc() -> game.Pawn_Input {
	cmd := gather_local_command()
	hand_note_command(cmd)
	return cmd
}

@(private = "file")
gather_local_command :: proc() -> game.Pawn_Input {
	input_: game.Pawn_Input
	input_.yaw = camera.yaw
	input_.pitch = camera.pitch
	input_.weapon_slot = -1

	// Before the cursor gate below: the probe stands in for mouse buttons that
	// are never pressed, and a headless run has no grabbed cursor to gate on.
	if cli.nade != "" {
		nade_override_input(&input_)
		return input_
	}

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
	// Plant/defuse: held, the server does the counting.
	if key_down(glfw.KEY_E) do input_.buttons += {.Use}

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
	//
	// With a grenade in hand the same bit means the underhand throw instead:
	// there is no scope to be in while holding one, so the bit is free to mean
	// the button. Together with .Fire above that is the whole throw input --
	// holding either winds up, letting go throws (game/throw.odin).
	if hand_busy() {
		if may_fire && glfw.GetMouseButton(g.window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS {
			input_.buttons += {.Zoom}
		}
	} else if weapon_state.zoom_active {
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
	if intent.select_change {
		intent.select_change = false
		input_.weapon_slot = intent.select
	}
	return input_
}

// --nade: select the grenade slot and work the throw on a slow cycle. The throw
// is a held mouse button and a number key, neither of which a headless test can
// press, so the flag writes them into the command instead.
@(private = "file")
nade_override_input :: proc(input_: ^game.Pawn_Input) {
	if cli.nade == "" do return
	if !net_client.joined || !player.alive do return

	// Well clear of THROW_COOLDOWN, so each cycle is one throw and the log
	// reads as one line per grenade rather than a burst.
	period := f32(2.5)
	phase := f32(game.clock.tick_count) * game.TICK_DT
	cycle := int(phase / period)
	slice := phase - f32(cycle) * period

	// Early in the cycle: rebuy, then put one in hand. The rebuy repeats
	// rather than firing once on a phase change, because a buy that arrives
	// before the join completes is dropped by the server and a probe that
	// depends on winning that race is a flaky test.
	if slice < game.TICK_DT * 2 {
		nade_buy_send()
		input_.weapon_slot = game.GRENADE_SLOT
		return
	}

	// The wind-up, held for as long as --nade-charge asks and then released.
	// The release is what throws, so the window has to end well inside the
	// cycle -- one that ran to the next would never let go of the button.
	NADE_WIND_START :: f32(0.3)
	hold := max(cli.nade_charge, 0) * f32(game.THROW_CHARGE_TICKS) * game.TICK_DT
	hold = max(hold, game.TICK_DT * 2) // even charge 0 has to press
	if slice < NADE_WIND_START || slice >= NADE_WIND_START + hold do return

	// Deliberately standing still. Strafing through the wind-up was tried, to
	// exercise the motion a throw inherits -- it walks the probe into walls and
	// under fire, and the screenshot this flag exists for stops landing. The
	// moving case is covered by the wind-up tests and by hand.
	//
	// The style alternates by cycle rather than by a counter across respawns:
	// a grenade with a carry limit of one gives a life a single throw, and a
	// static counter would make which style that is depend on how the round
	// went. Even cycles are underhand, so the first throw of any run lands at
	// the thrower's own feet -- which is what lets a headless run prove an
	// effect at all, since self-damage needs no second player to walk into it.
	input_.buttons += cycle % 2 == 0 ? {.Zoom} : {.Fire}
}
