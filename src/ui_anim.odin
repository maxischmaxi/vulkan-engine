package main

import "core:math"
import "game"

// The UI's clock and motion vocabulary. Screens stay immediate-mode; the only
// retained state is here: how long the current screen has been up, and the
// scene transition in flight. Widget hover state joins in ui.odin.

UI_TRANS_SECONDS :: f32(0.28)
UI_ENTER_SECONDS :: f32(0.25)
UI_ENTER_STAGGER :: f32(0.04)
UI_ENTER_SHIFT :: f32(24) // reference px a screen element slides up on entry

Ui_Transition :: struct {
	active: bool,
	target: Scene,
	t:      f32, // 0..1 across the whole fade-through
	fired:  bool, // enter_scene has run, at the midpoint
}

Ui_State :: struct {
	frame:      u64,
	dt:         f32,
	last_scene: Scene,
	screen_age: f32, // seconds since the current scene appeared
	pin_active: bool,
	pin_age:    f32,
	trans:      Ui_Transition,
	anims:      map[u64]Ui_Anim, // widget hover state, keyed by ui_id
	active_id:  u64, // the slider owning the current drag, 0 for none
}

ui: Ui_State

ease_out_cubic :: proc(t: f32) -> f32 {
	it := 1 - t
	return 1 - it * it * it
}

ease_in_out_cubic :: proc(t: f32) -> f32 {
	return t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) * 0.5
}

ease_out_expo :: proc(t: f32) -> f32 {
	return t >= 1 ? 1 : 1 - math.pow(2, -10 * t)
}

// Framerate-independent approach: the classic 1-exp(-dt*rate) step, so hover
// eases identically at 60 and 240 fps.
ui_approach :: proc(current, target, dt, rate: f32) -> f32 {
	return current + (target - current) * (1 - math.exp(-dt * rate))
}

// The per-frame tick, called once from build_hud before any drawing. Detects
// scene changes on its own, so enter_scene needs no hook for entrance motion.
ui_frame_begin :: proc() {
	ui.frame += 1
	ui.dt = game.clock.frame_dt

	// a drag ends the moment the button is up, wherever the cursor is
	if !input.mouse_down do ui.active_id = 0

	if scene.current != ui.last_scene {
		ui.last_scene = scene.current
		ui.screen_age = 0
	} else {
		ui.screen_age += ui.dt
	}

	// The preview harness pins the clock so screenshots are deterministic.
	// One-shot: the harness re-pins every frame while it runs.
	if ui.pin_active {
		ui.screen_age = ui.pin_age
		ui.pin_active = false
	}

	if ui.trans.active {
		ui.trans.t += ui.dt / UI_TRANS_SECONDS
		if ui.trans.t >= 0.5 && !ui.trans.fired {
			ui.trans.fired = true
			// All side effects (cursor, netcode, camera park) run under full
			// cover, which also hides the camera snap a hard cut shows today.
			enter_scene(ui.trans.target)
		}
		if ui.trans.t >= 1 do ui.trans.active = false
	}
}

// The animated way to change scenes: fade to UI_BG, switch at the midpoint,
// fade back out. User-driven navigation goes through here; programmatic jumps
// (connect failures, queue delivery) keep calling enter_scene directly.
scene_transition_to :: proc(next: Scene) {
	if ui.trans.active && !ui.trans.fired {
		ui.trans.target = next // still covered; just redirect
		return
	}
	ui.trans = {
		active = true,
		target = next,
	}
}

// A direct scene change takes an in-flight fade over: its midpoint would
// otherwise switch back to the scene it was aimed at, undoing the newer one.
// That is not hypothetical -- picking a team arms a fade to .Connecting, and
// the server's phase lands enter_scene(.Playing) inside those 140 ms every
// time on a local server. The fade keeps running so the screen still uncovers;
// only its pending side effect is cancelled.
ui_transition_claim :: proc() {
	if !ui.trans.active || ui.trans.fired do return
	ui.trans.fired = true
	ui.trans.t = max(ui.trans.t, 0.5) // past the midpoint: uncover from here
}

ui_transition_active :: proc() -> bool {
	return ui.trans.active
}

// Drawn over everything, including the early-return menu paths.
ui_draw_transition_scrim :: proc(width, height: f32) {
	if !ui.trans.active do return
	t := ui.trans.t
	half := t < 0.5 ? t * 2 : 2 - t * 2
	alpha := half * half * (3 - 2 * half) // smoothstep both ways
	color := UI_BG
	color.a = alpha
	hud_rect(0, 0, width, height, color)
}

ui_screen_age :: proc() -> f32 {
	return ui.screen_age
}

ui_anim_pin :: proc(age: f32) {
	ui.pin_active = true
	ui.pin_age = age
}

// Staggered entrance for screen elements: index 0 leads, each next element
// trails by UI_ENTER_STAGGER. Callers add dy to y and multiply their alpha.
ui_entrance :: proc(index: int) -> (dy: f32, alpha: f32) {
	t := clamp((ui.screen_age - f32(index) * UI_ENTER_STAGGER) / UI_ENTER_SECONDS, 0, 1)
	e := ease_out_cubic(t)
	return (1 - e) * UI_ENTER_SHIFT * hud_scale(), e
}
