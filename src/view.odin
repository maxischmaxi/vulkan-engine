package main

import "core:math"
import "game"

// Everything between the player's feet and the eye the camera renders from.
//
// The simulation moves the body in hard jumps: step_move lifts it a whole stair
// inside one tick, snap_to_ground drops it one the same way, a landing stops it
// dead, ducking halves its height between two frames. Bolting the camera
// straight onto that is what makes a first-person view feel shaken rather than
// carried, and dust2 is mostly stairs. Counter-strike answers it the same way:
// the body teleports, the eye catches up.
//
// The stair smoothing works on the rendered position, not on move events: the
// render lerp already spreads every tick's jump across the tick, so booking the
// same jump again from an event counts it twice and shakes the eye by exactly
// the amount it was meant to hide. game.smooth_feet_z holds the whole contract;
// this file only keeps its state between frames.
//
// None of this reaches the simulation. Shots still leave from wherever the eye
// is, so the smoothing changes what you see, never whether you hit.

// How fast the eye closes on the feet after a step, up or down. 3.8 m/s clears
// the tallest stair in about 120 ms, fast enough not to read as lag, slow
// enough to kill the jolt -- and it matches a full-speed stair descent almost
// exactly, so running down stairs renders as one constant slide.
STEP_SMOOTH_SPEED :: f32(3.8)

// The landing dip is a critically damped spring rather than a value that snaps
// down and eases back -- the snap would be the very jolt this is here to remove.
// omega = 18 puts the deepest point about 55 ms after impact and has it settled
// inside 0.3 s; the stiffness and damping below are omega^2 and 2*omega.
LAND_STIFFNESS :: f32(324)
LAND_DAMPING :: f32(36)

// Impact speed that earns the full dip, and the downward kick that produces it.
// A critically damped spring peaks at kick/(omega*e), so 4.4 m/s gives 9 cm.
LAND_SPEED_FULL :: f32(9.0)
LAND_KICK :: f32(4.4)

// One long frame -- a stall, a breakpoint -- would push the spring past the
// point it can come back from, so it advances in steps of its own.
LAND_MAX_STEP :: f32(1.0) / 120

// Ducking is a stance change, not a fall, so the eye slides between the two
// heights. Exponential rather than linear because it has no arrival edge:
// tapping crouch repeatedly must not produce a series of stops.
STANCE_SPEED :: f32(16)

// Insurance, not tuning. No combination of the offsets below should put the eye
// this low, and if one ever does, the camera still must not sink into the floor.
MIN_EYE_HEIGHT :: f32(0.15)

View :: struct {
	eye_height:    f32, // eases towards the standing or ducked height
	land_offset:   f32, // landing dip, negative while dipping
	land_velocity: f32,
	smooth_z:      f32, // feet z the camera rode last frame, world space
	raw_z:         f32, // interpolated feet z last frame, the smoothing's base
}

view: View

init_view :: proc() {
	// Straight to the target, not eased towards it: a spawn is not a movement.
	view = View {
		eye_height = player_eye_height_target(),
		smooth_z   = player.body.position.z,
		raw_z      = player.body.position.z,
	}
}

// A correction moved the feet outright -- a round reset, a teleport the
// prediction only learns about from the server. Not a movement, so nothing to
// smooth over.
view_reset_feet :: proc() {
	view.smooth_z = player.body.position.z
	view.raw_z = player.body.position.z
}

// Scaled by how hard the ground was hit, so stepping off a crate and falling off
// the catwalk are not the same event.
view_note_landing :: proc(impact_speed: f32) {
	if impact_speed <= 0 do return
	view.land_velocity -= min(impact_speed / LAND_SPEED_FULL, 1) * LAND_KICK
}

// Runs once per rendered frame rather than per tick. This is what the eye looks
// like right now, and it should be as smooth as the display can show -- stepping
// it at 64 Hz would leave it as coarse as the thing it is smoothing.
view_update :: proc(dt: f32) {
	if dt <= 0 do return

	target := player_eye_height_target()
	view.eye_height += (target - view.eye_height) * (1 - math.exp(-STANCE_SPEED * dt))
	if abs(target - view.eye_height) < 0.001 {
		view.eye_height = target
	}

	remaining := dt
	for remaining > 0 {
		sub := min(remaining, LAND_MAX_STEP)
		remaining -= sub

		accel := -LAND_STIFFNESS * view.land_offset - LAND_DAMPING * view.land_velocity
		view.land_velocity += accel * sub
		view.land_offset += view.land_velocity * sub
	}
}

// The camera's z this frame, given the interpolated feet. Owns the insurance
// clamp because only this proc sees both the real and the smoothed feet.
view_camera_z :: proc(feet_z: f32, on_ground: bool, dt: f32) -> f32 {
	view.smooth_z = game.smooth_feet_z(
		view.smooth_z,
		view.raw_z,
		feet_z,
		on_ground,
		STEP_SMOOTH_SPEED,
		game.STEP_HEIGHT,
		dt,
	)
	view.raw_z = feet_z
	return max(view.smooth_z + view.eye_height + view.land_offset, feet_z + MIN_EYE_HEIGHT)
}
