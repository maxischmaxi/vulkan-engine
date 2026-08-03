package game

import "../physics"
import "core:math/linalg"

// Where a throw would go, flown forward from the hand. What the client draws
// its white line from.
//
// This lives in the shared package and not with the renderer for one reason:
// the line is a promise. Anything that recomputed the flight its own way would
// eventually promise something the server does not deliver, and a utility game
// is unplayable the moment the preview and the grenade disagree. So the step is
// the simulation's step, the integration is the simulation's integration
// (physics/bounce.odin), and the velocity comes from the same throw_velocity
// both ends call.
//
// The one deliberate difference: this STOPS at the first surface instead of
// bouncing off it. A bounce turns a fraction of a degree of aim into metres of
// landing spot, so a predicted second leg would be confident and wrong -- the
// worst combination a preview can have. The circle marks where it would first
// touch, and what happens after that is the player's problem, as it is in
// counter-strike.

// The step has to be the simulation's tick, not a coarser one. Semi-implicit
// Euler under gravity carries an error of about g*t*dt/2, so stepping at twice
// the tick would put the far end of a two-second throw a third of a metre off
// -- which is exactly the distance that decides whether a smoke lands in the
// choke or on the box beside it.
ARC_STEP :: TICK_DT

// Three seconds of flight. Past that a throw is either resting somewhere the
// line already reached or gone over the map.
ARC_MAX_POINTS :: 192

Throw_Arc :: struct {
	points:     [ARC_MAX_POINTS][3]f32,
	count:      int,
	// Whether the flight ran into something inside the horizon above, and
	// where. The last point equals hit_point when it did.
	hit:        bool,
	hit_point:  [3]f32,
	hit_normal: [3]f32,
}

predict_throw_arc :: proc(
	grid: ^physics.Grid,
	origin, velocity: [3]f32,
	radius: f32,
) -> (
	arc: Throw_Arc,
) {
	position := origin
	speed := velocity

	arc.points[0] = position
	arc.count = 1

	for arc.count < ARC_MAX_POINTS {
		// Gravity before the move, as bounce_move does it. The order is worth
		// a line: applying it after would land every point one step ahead of
		// where the grenade will actually be.
		speed.z -= GRAVITY * ARC_STEP

		step := speed * ARC_STEP
		distance := linalg.length(step)
		if distance < 1e-6 do break
		direction := step / distance

		// A radius short of the surface, so the sphere stops against the wall
		// rather than halfway inside it -- the same correction the flight makes.
		if hit, ok := physics.grid_raycast(grid, position, direction, distance + radius);
		   ok && hit.t <= distance + radius {
			arc.hit = true
			arc.hit_point = hit.point
			arc.hit_normal = hit.normal
			arc.points[arc.count] = position + direction * max(hit.t - radius, 0)
			arc.count += 1
			return
		}

		position += step
		arc.points[arc.count] = position
		arc.count += 1

		// Out of the world: the same floor the projectile gives up at.
		if position.z < -50 do break
	}
	return
}
