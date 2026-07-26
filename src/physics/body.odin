package physics

import "core:math"

// A moving box: the player, a bot, anything that walks. Position is at the feet
// and horizontally centred, which is the convention the whole map is built
// around.
Body :: struct {
	position:  [3]f32,
	velocity:  [3]f32,
	radius:    f32, // horizontal half-extent
	height:    f32,
	step:      f32, // tallest ledge walked over without jumping
	on_ground: bool,
}

// How far a body may already be inside a box before a correction is treated as
// pre-existing overlap rather than something this step caused.
PENETRATION_SLOP :: 1e-4

// The overlap test runs after the step, so a step longer than an obstacle is
// thick would pass clean through it without ever overlapping. Long moves are
// therefore split into pieces shorter than the thinnest collision geometry in
// the map (the 6 cm indoor floor slabs). Relying on the tick rate to keep steps
// small instead would make collision silently depend on frame timing.
MAX_SUBSTEP :: 0.05

body_aabb :: proc(b: Body) -> Aabb {
	return {
		min = {b.position.x - b.radius, b.position.y - b.radius, b.position.z},
		max = {b.position.x + b.radius, b.position.y + b.radius, b.position.z + b.height},
	}
}

body_aabb_at :: proc(b: Body, position: [3]f32) -> Aabb {
	moved := b
	moved.position = position
	return body_aabb(moved)
}

// Moves along one axis, splitting the move so no single step can skip over an
// obstacle. Stops at the first thing it runs into.
move_axis :: proc(body: ^Body, boxes: []Aabb, axis: int, delta: f32) -> (blocked: bool) {
	if delta == 0 do return false

	steps := int(math.ceil(abs(delta) / MAX_SUBSTEP))
	sub := delta / f32(steps)

	for _ in 0 ..< steps {
		if move_axis_substep(body, boxes, axis, sub) do return true
	}
	return false
}

// One indivisible step. The other two axes were free before it, so only this one
// can be responsible for a new overlap.
move_axis_substep :: proc(body: ^Body, boxes: []Aabb, axis: int, delta: f32) -> (blocked: bool) {
	old := body.position[axis]
	body.position[axis] += delta

	for box in boxes {
		if !overlaps(body_aabb(body^), box) do continue

		target: f32
		if delta > 0 {
			// leading edge is the body's max on this axis
			extent: f32 = axis == 2 ? body.height : body.radius
			target = box.min[axis] - extent
		} else {
			// the feet are the origin, so the downward extent is zero
			extent: f32 = axis == 2 ? 0 : body.radius
			target = box.max[axis] + extent
		}

		// Only snap to a face this step could actually have crossed. Standing on
		// a thin floor slab means permanently overlapping it by its thickness,
		// and without this check the tiniest sideways drift -- the 1e-12 that
		// cos(90 degrees) is not -- would snap the body out across the slab's
		// full width instead of leaving it where it is.
		if abs(target - old) > abs(delta) + PENETRATION_SLOP {
			body.position[axis] = old
		} else {
			body.position[axis] = target
		}
		blocked = true
	}
	return
}

horizontal_distance :: proc(a, b: [3]f32) -> f32 {
	dx := a.x - b.x
	dy := a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
}

// Horizontal move that retries from a raised position when something is in the
// way, then settles back down. That single retry is the whole of stair climbing.
step_move :: proc(body: ^Body, boxes: []Aabb, dx, dy: f32) {
	start := body.position

	move_axis(body, boxes, 0, dx)
	move_axis(body, boxes, 1, dy)
	flat := body.position

	if !body.on_ground do return

	// close enough to the requested move means nothing worth stepping over
	wanted := math.sqrt(dx * dx + dy * dy)
	got := horizontal_distance(flat, start)
	if got >= wanted - 0.001 do return

	// retry elevated, but only if there is headroom up there
	body.position = start
	body.position.z += body.step
	if overlaps_any(body_aabb(body^), boxes) {
		body.position = flat
		return
	}

	move_axis(body, boxes, 0, dx)
	move_axis(body, boxes, 1, dy)
	move_axis(body, boxes, 2, -body.step)

	if horizontal_distance(body.position, start) <= got {
		body.position = flat
	}
}

// Gravity plus the vertical move and its ground/ceiling response. Shared by the
// player and the bots so both agree on what standing on something means.
apply_gravity :: proc(body: ^Body, boxes: []Aabb, gravity, dt: f32) {
	body.velocity.z -= gravity * dt

	if move_axis(body, boxes, 2, body.velocity.z * dt) {
		// landing clears downward speed, hitting a ceiling clears upward speed
		body.on_ground = body.velocity.z < 0
		body.velocity.z = 0
	} else {
		body.on_ground = false
	}
}
