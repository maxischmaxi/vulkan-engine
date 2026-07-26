package main

import "core:log"
import "vendor:glfw"

// Everything the game does only because a developer is watching. Two questions
// live here and nothing else answers them: is this a debug build, and are the
// tools switched on right now.
//
// The split matters. ODIN_DEBUG says how the binary was compiled; debug.enabled
// says whether the overlay and its shortcuts are live. A release build with
// -define:DEBUG_TOOLS=true gets the tools without the validation layer and
// without -o:none, which is the only way to debug something that only misbehaves
// at full speed.
DEBUG_TOOLS :: #config(DEBUG_TOOLS, ODIN_DEBUG)

Debug_State :: struct {
	enabled:       bool,
	god_mode:      bool,
	infinite_ammo: bool,
	fps:           f32, // smoothed, for the overlay
}

debug: Debug_State

// The one question the rest of the codebase asks. In a build without the tools
// DEBUG_TOOLS is a false constant, so every `if debug_active()` folds away and
// the branch costs nothing.
debug_active :: proc() -> bool {
	return DEBUG_TOOLS && debug.enabled
}

// A shortcut and the label the overlay prints for it, in one place. Adding a
// tool means adding a line here -- the HUD reads the same table, so a shortcut
// can never exist without being documented on screen.
Debug_Action :: struct {
	key:      i32,
	// Spelled out rather than derived from the keycode: a lookup table mapping
	// GLFW constants back to names would be a second list to keep in step with
	// this one.
	key_name: string,
	label:    string,
	run:      proc(),
	// nil for one-shots. Toggles report their state so the overlay can show it.
	state:    proc() -> bool,
}

DEBUG_ACTIONS := []Debug_Action {
	{glfw.KEY_F7, "F7", "REFILL AMMO", debug_refill_ammo, nil},
	{glfw.KEY_F8, "F8", "FULL HEAL", debug_full_heal, nil},
	{glfw.KEY_F9, "F9", "KILL BOTS", debug_kill_bots, nil},
	{glfw.KEY_F10, "F10", "GOD MODE", proc() {
			debug.god_mode = !debug.god_mode
			log.infof("God mode {}", debug.god_mode ? "on" : "off")
		}, proc() -> bool {return debug.god_mode}},
	{glfw.KEY_F11, "F11", "INFINITE AMMO", proc() {
			debug.infinite_ammo = !debug.infinite_ammo
			log.infof("Infinite ammo {}", debug.infinite_ammo ? "on" : "off")
		}, proc() -> bool {return debug.infinite_ammo}},
}

// The render debug views. Always compiled, because they are as useful for
// looking at the lighting in a shipped build as they are while writing it.
Debug_View :: struct {
	key:  i32,
	mode: Debug_Mode,
}

DEBUG_VIEWS := []Debug_View {
	{glfw.KEY_F1, .None},
	{glfw.KEY_F2, .Cascades},
	{glfw.KEY_F3, .Albedo},
	{glfw.KEY_F4, .Normals},
	{glfw.KEY_F5, .Lighting},
}

init_debug :: proc() {
	debug.enabled = DEBUG_TOOLS
	if DEBUG_TOOLS {
		// GLFW calls it grave accent; on the keyboards this is developed on the
		// keycap says ^, which is what the overlay prints.
		log.infof("Debug tools on ({} shortcuts, ^ toggles the overlay)", len(DEBUG_ACTIONS))
	}
}

// Runs once per frame, right after the keyboard snapshot.
update_debug :: proc() {
	if clock.frame_dt > 0 {
		// Exponentially smoothed: 1/dt straight off the clock flickers too fast
		// to read a digit of.
		instant := 1.0 / clock.frame_dt
		debug.fps = debug.fps <= 0 ? instant : debug.fps + (instant - debug.fps) * 0.1
	}

	for view in DEBUG_VIEWS {
		if key_pressed(view.key) do set_debug_mode(view.mode)
	}

	if key_pressed(glfw.KEY_F6) {
		clear_decals()
		log.info("Decals cleared")
	}

	// Folded out entirely when the tools are not compiled in, so the key stays
	// free for something else.
	if DEBUG_TOOLS && key_pressed(glfw.KEY_GRAVE_ACCENT) {
		debug.enabled = !debug.enabled
		log.infof("Debug tools {}", debug.enabled ? "on" : "off")
	}

	if !debug_active() do return

	for action in DEBUG_ACTIONS {
		if key_pressed(action.key) do action.run()
	}
}

set_debug_mode :: proc(mode: Debug_Mode) {
	debug_mode = mode
	log.infof("Debug view: {}", mode)
}

// ------------------------------------------------------------------- actions

debug_refill_ammo :: proc() {
	refill_all_ammo()
	log.info("Ammo refilled")
}

debug_full_heal :: proc() {
	if !player.alive do respawn_player()
	player.health = PLAYER_MAX_HEALTH
	player.armor = PLAYER_MAX_ARMOR
	log.info("Healed")
}

debug_kill_bots :: proc() {
	killed := 0
	for &bot in bots {
		if !bot.alive do continue
		kill_bot(&bot)
		killed += 1
	}
	log.infof("Killed {} bots", killed)
}
