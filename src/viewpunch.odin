package main

import "core:math"
import "core:math/linalg"
import "game"

// The camera's answer to firing: a render-only kick that tracks a fraction of
// the ballistic recoil, counter-strike style. The mouse-pull that keeps the
// bullets on target is bigger than what the screen shows -- the rest is feel,
// not information.
//
// The punch lives ONLY in the rendered view. It never touches camera.yaw or
// camera.pitch -- those go on the wire, and a punch that fed back into the
// wire would compensate itself. Everything wire-bound (intent, prediction,
// the cosmetic shot trace, minimap, damage indicator) reads the raw fields;
// everything rendered reads punched_view_angles via camera_forward/right.

Viewpunch :: struct {
	current:     [2]f32, // degrees {yaw, pitch} added to the rendered view only
	// A blast's shove, kept apart from the tracked recoil above: `current`
	// chases the spray pattern every frame and would erase anything added to
	// it within a frame or two.
	shake:       f32, // amplitude in degrees, decaying
	shake_phase: f32,
}

viewpunch: Viewpunch

// How a blast shoves the view. Past the range nothing happens at all, which
// keeps a smoke going off across the map from nudging a duel.
BLAST_SHAKE_RANGE :: f32(20)
BLAST_SHAKE_DEGREES :: f32(2.4)
BLAST_SHAKE_FREQ :: f32(26)
BLAST_SHAKE_DECAY :: f32(6.5)

// The fraction of the ballistic pattern the camera shows (cs shows ~0.45 of
// its aim punch). The rest stays hidden, which is exactly what keeps a
// counter-steered burst from storing degrees the screen must give back.
VIEWPUNCH_TRACKING :: 0.45

// One always-on chase rate. The target itself is continuous -- the burst
// depth decays instead of resetting -- so there is no burst-end rate flip and
// no snap, by construction.
VIEWPUNCH_RATE :: 30.0

// Per-shot kick: the immediate feedback the chase then folds into the
// pattern. Scaled off the viewmodel's recoil_kick so the table stays the one
// source of how violent a weapon is.
PUNCH_DEG_PER_METRE :: 15.0

viewpunch_update :: proc(dt: f32) {
	target :=
		game.spray_track_offset(&weapon_state.spray, current_weapon().mag_size) *
		VIEWPUNCH_TRACKING
	viewpunch.current += (target - viewpunch.current) * (1 - math.exp(-VIEWPUNCH_RATE * dt))

	viewpunch.shake_phase += dt
	viewpunch.shake *= math.exp(-BLAST_SHAKE_DECAY * dt)
	if viewpunch.shake < 0.001 do viewpunch.shake = 0
}

// Something went off nearby. `strength` is 1 for a grenade at full force; the
// distance falloff is this procedure's business, because only it knows where
// the eye is.
//
// Takes the louder of the two rather than adding: two grenades landing together
// should shake like the bigger one, not like their sum -- that way lies a view
// that spins.
viewpunch_note_blast :: proc(position: [3]f32, strength: f32) {
	distance := linalg.length(position - camera.position)
	falloff := 1 - clamp(distance / BLAST_SHAKE_RANGE, 0, 1)
	if falloff <= 0 do return

	// Squared, so the shove is felt at the blast and merely noticed at the edge
	// of its range.
	amplitude := BLAST_SHAKE_DEGREES * strength * falloff * falloff
	if amplitude <= viewpunch.shake do return
	viewpunch.shake = amplitude
	viewpunch.shake_phase = 0
}

// The two axes run at different rates, so the view describes a wandering figure
// rather than a diagonal line -- a single frequency on both reads as the screen
// being dragged, not shaken.
@(private = "file")
shake_offset :: proc() -> [2]f32 {
	if viewpunch.shake <= 0 do return {}
	t := viewpunch.shake_phase
	return {
		math.sin(t * BLAST_SHAKE_FREQ) * viewpunch.shake,
		math.sin(t * BLAST_SHAKE_FREQ * 0.71 + 1.3) * viewpunch.shake * 0.8,
	}
}

// Called on every cosmetic shot: a sharp nudge upward that the chase pulls
// back toward the tracked pattern.
viewpunch_note_shot :: proc() {
	viewpunch.current.y += current_weapon().recoil_kick * PUNCH_DEG_PER_METRE
}

// The angles the world is rendered through. Clamped just inside MAX_PITCH so
// a punched view can never degenerate the look-at.
//
// Scaled by the lens the same way camera_apply_mouse scales the mouse: a punch
// is a distance across the screen, not an angle the player reads, and the same
// degrees cover three times that distance through a 30 degree scope. Unscaled,
// a scoped shot threw the whole picture -- and with it the streak the shot left
// behind -- a tenth of the sight picture downward on the frame it fired.
//
// The state stays lens-independent; only this read scales. Nothing here reaches
// the wire or the prediction: camera.yaw and camera.pitch are untouched.
punched_view_angles :: proc() -> (yaw, pitch: f32) {
	lens := camera.fov_horizontal / game_settings.fov
	offset := viewpunch.current + shake_offset()
	return camera.yaw + offset.x * lens,
		clamp(camera.pitch + offset.y * lens, -MAX_PITCH + 0.5, MAX_PITCH - 0.5)
}
