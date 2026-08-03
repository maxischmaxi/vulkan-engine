package physics

import "core:math/linalg"

// A small round thing thrown through the world: it flies, it hits walls, it
// bounces off them and eventually it lies still. Grenades are the only user so
// far, and everything about how *bouncy* one is stays with the caller -- this
// file knows the geometry, not the game.
//
// Unlike Body, which is a hull that slides along surfaces and steps up stairs,
// this is a point with a radius that reflects. The two have nothing in common
// beyond the boxes they collide against.

// Iterations of hit-and-reflect inside one step. A grenade in a corner can
// need two or three; past this the remaining motion is dropped, which is the
// safe direction -- the thing stops rather than tunnelling through a wall.
MAX_BOUNCES_PER_STEP :: 4

// Below this speed a resting projectile is considered stopped rather than
// creeping. In metres per second.
BOUNCE_REST_SPEED :: f32(0.35)

Bounce_Result :: struct {
	bounces:  int,
	hit_wall: bool, // touched anything at all this step
	resting:  bool, // ended the step stopped on a surface
}

// One step of ballistic motion with reflection.
//
// `restitution` is how much speed survives a bounce along the surface normal
// (0 = dead stop, 1 = perfectly elastic); `friction` is how much of the
// tangential component survives, which is what stops a grenade sliding forever
// on a flat floor.
//
// Deterministic: no randomness, and every branch is decided by the same
// comparisons on both ends of a wire.
bounce_move :: proc(
	g: ^Grid,
	position: ^[3]f32,
	velocity: ^[3]f32,
	radius: f32,
	gravity: f32,
	restitution: f32,
	friction: f32,
	dt: f32,
) -> (
	result: Bounce_Result,
) {
	if dt <= 0 do return

	velocity.z -= gravity * dt

	remaining := dt
	for _ in 0 ..< MAX_BOUNCES_PER_STEP {
		step := velocity^ * remaining
		distance := linalg.length(step)
		if distance < 1e-6 do break

		direction := step / distance
		// The ray starts at the centre and has to stop a radius short of the
		// surface, or the sphere ends up half inside the wall.
		hit, ok := grid_raycast(g, position^, direction, distance + radius)
		if !ok || hit.t > distance + radius {
			position^ += step
			break
		}

		result.hit_wall = true
		result.bounces += 1

		// Back off along the normal rather than along the incoming ray: in a
		// corner the latter would push the projectile into the other wall.
		travel := max(hit.t - radius, 0)
		position^ += direction * travel
		position^ += hit.normal * 1e-3

		normal_speed := linalg.dot(velocity^, hit.normal)
		normal_part := hit.normal * normal_speed
		tangent := velocity^ - normal_part
		// Only reflect when actually moving into the surface; a grazing pass
		// whose normal component already points away must not gain speed.
		if normal_speed < 0 {
			velocity^ = tangent * friction - normal_part * restitution
		} else {
			velocity^ = tangent * friction + normal_part
		}

		used := distance > 0 ? travel / distance : 1
		remaining *= (1 - used)
		if remaining <= 0 do break
	}

	// Resting is a question about the surface below, not about speed alone: a
	// grenade at the top of its arc is slow too.
	if linalg.length(velocity^) < BOUNCE_REST_SPEED {
		if _, grounded := grid_raycast(g, position^, {0, 0, -1}, radius + 0.05); grounded {
			velocity^ = {}
			result.resting = true
		}
	}
	return
}
