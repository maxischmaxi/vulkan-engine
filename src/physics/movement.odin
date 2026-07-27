package physics

import "core:math"

// Quake's movement equations, the way Source still runs them and therefore the
// way counter-strike feels. Three procedures do the whole job: friction bleeds
// speed off on the ground, acceleration adds it back in the direction you asked
// for, and the airborne variant is the same thing with the wish speed capped so
// low that steering is all that is left.
//
// That cap is the entire trick behind air-strafing and bunny-hopping. Only the
// component of the current velocity along the wish direction is measured against
// it -- speed sideways to it is neither seen nor limited. Turn the view so the
// wish direction stays nearly perpendicular to where you are already moving and
// the measured speed stays near zero, so there is always room for another
// helping, tick after tick, and the vector sum grows. Nothing below is
// special-cased for it; it falls out of the equations.

// Speed under which a body standing on the ground is simply stopped. Friction is
// proportional to speed, so without a floor under it the last fraction of a
// metre per second would take forever to shed and the player would drift.
MIN_GROUND_SPEED :: 0.05

// Ground friction. Below `stop_speed` the drop is computed as if the body were
// moving at `stop_speed`, which is what brings it to a halt in a fixed time
// rather than along an asymptote.
apply_friction :: proc(velocity: ^[3]f32, friction, stop_speed, dt: f32) {
	speed := horizontal_speed(velocity^)
	if speed < MIN_GROUND_SPEED {
		velocity.x = 0
		velocity.y = 0
		return
	}

	control := max(speed, stop_speed)
	scale := max(speed - control * friction * dt, 0) / speed
	velocity.x *= scale
	velocity.y *= scale
}

// Adds speed along `wish_dir`, never past `wish_speed` as measured along that
// same direction. Speed at right angles to it is not measured and therefore not
// capped, which is why a hard turn on the ground keeps everything you had.
accelerate :: proc(velocity: ^[3]f32, wish_dir: [3]f32, wish_speed, accel, dt: f32) {
	add := wish_speed - (velocity.x * wish_dir.x + velocity.y * wish_dir.y)
	if add <= 0 do return

	gain := min(accel * wish_speed * dt, add)
	velocity.x += gain * wish_dir.x
	velocity.y += gain * wish_dir.y
}

// Airborne. The wish speed is capped for the headroom test but deliberately not
// for the size of a single step: at 30 units a second one tick would be worth
// half a centimetre and air control would amount to nothing. Source has the same
// asymmetry, and it is what makes a strafe jump gain rather than merely steer.
air_accelerate :: proc(
	velocity: ^[3]f32,
	wish_dir: [3]f32,
	wish_speed, max_wish_speed, accel, dt: f32,
) {
	add := min(wish_speed, max_wish_speed) - (velocity.x * wish_dir.x + velocity.y * wish_dir.y)
	if add <= 0 do return

	gain := min(accel * wish_speed * dt, add)
	velocity.x += gain * wish_dir.x
	velocity.y += gain * wish_dir.y
}

// ---------------------------------------------------------------- the stance

// Ducking. On the ground the hull simply loses height off the top, because the
// origin is at the feet and nothing has to move.
//
// In mid-air it is the interesting one: the hull shrinks around its own centre,
// so the feet come up by half of what was lost while the head comes down by the
// other half. That lift is the whole of the crouch-jump -- it puts the feet over
// ledges a standing jump cannot clear, which is exactly what tucking your legs
// up does. The new hull sits strictly inside the old one, so unlike standing
// back up this can never end with the body inside something and needs no test.
//
// Source lifts the feet by the full amount instead, keeping the head fixed. With
// a 1.8 m hull that would be 0.9 m of free reach on top of the jump, enough to
// turn most walls into ledges; half of it is the same trick at a height a map
// can be built around.
//
// Returns how far the feet moved, which the camera has to unwind -- a jump in
// the eye position is a jolt whatever caused it.
duck_hull :: proc(body: ^Body, ducked_height: f32) -> (feet_moved: f32) {
	if ducked_height >= body.height do return 0

	if !body.on_ground {
		feet_moved = (body.height - ducked_height) * 0.5
		body.position.z += feet_moved
	}
	body.height = ducked_height
	return
}

// Standing back up, which does need the room. On the ground the hull grows into
// the space above; in mid-air the feet drop back to where they would have been.
// Either way, no room means staying ducked -- that is what keeps a player from
// rising through a ceiling, or from putting their feet through the ledge they
// are about to land on.
stand_hull :: proc(
	body: ^Body,
	boxes: []Aabb,
	standing_height: f32,
) -> (
	feet_moved: f32,
	ok: bool,
) {
	if standing_height <= body.height do return 0, true

	grown := body^
	grown.height = standing_height
	if !body.on_ground {
		grown.position.z -= (standing_height - body.height) * 0.5
	}

	if overlaps_any(body_aabb(grown), boxes) do return 0, false

	feet_moved = grown.position.z - body.position.z
	body^ = grown
	return feet_moved, true
}

// A bound on the horizontal speed, not a gameplay limit: chained perfectly, the
// equations above have no fixed point, and every collision test costs more the
// faster a body travels.
clamp_horizontal_speed :: proc(velocity: ^[3]f32, limit: f32) {
	speed := horizontal_speed(velocity^)
	if speed <= limit do return

	scale := limit / speed
	velocity.x *= scale
	velocity.y *= scale
}

horizontal_speed :: proc(velocity: [3]f32) -> f32 {
	return math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
}
