package main

import "core:log"
import "core:math/linalg"
import "vendor:glfw"

// Roughly the counter-strike player: 32x32x72 units at 0.0254 m per unit.
PLAYER_RADIUS :: 0.3
PLAYER_HEIGHT :: 1.8
EYE_HEIGHT :: 1.65

WALK_SPEED :: 6.4 // 250 units/s
SLOW_FACTOR :: 0.45
NOCLIP_SPEED :: 22.0

GRAVITY :: 18.0
JUMP_SPEED :: 5.0 // clears about 0.7 m

// Source calls this sv_stepsize (18 units). Anything shorter than this gets
// walked over without a jump, which is what makes the stairs feel like ramps.
STEP_HEIGHT :: 0.45

Player :: struct {
	position: [3]f32, // at the feet, centred horizontally
	velocity: [3]f32,
	on_ground: bool,
	noclip:   bool,
}

player: Player
world_brushes: []Brush

init_player :: proc(brushes: []Brush) {
	world_brushes = brushes
	player.position = SPAWN_POSITION
	player.velocity = {}
	player.on_ground = false
	player.noclip = false
}

player_min :: proc(p: [3]f32) -> [3]f32 {
	return {p.x - PLAYER_RADIUS, p.y - PLAYER_RADIUS, p.z}
}

player_max :: proc(p: [3]f32) -> [3]f32 {
	return {p.x + PLAYER_RADIUS, p.y + PLAYER_RADIUS, p.z + PLAYER_HEIGHT}
}

// Strict inequality so that resting exactly on a surface does not count as
// penetrating it -- otherwise standing still would trigger a push-out forever.
overlaps :: proc(p: [3]f32, b: Brush) -> bool {
	mn := player_min(p)
	mx := player_max(p)
	return(
		mn.x < b.max.x &&
		mx.x > b.min.x &&
		mn.y < b.max.y &&
		mx.y > b.min.y &&
		mn.z < b.max.z &&
		mx.z > b.min.z \
	)
}

overlaps_any :: proc(p: [3]f32) -> bool {
	for b in world_brushes {
		if overlaps(p, b) do return true
	}
	return false
}

// Moves along one axis and resolves whatever it ends up inside. Because the
// other two axes were already free before the step, only this axis can be
// responsible for a new overlap.
move_axis :: proc(axis: int, delta: f32) -> (blocked: bool) {
	if delta == 0 do return false

	old := player.position[axis]
	player.position[axis] += delta

	for b in world_brushes {
		if !overlaps(player.position, b) do continue

		target: f32
		if delta > 0 {
			// leading edge is the player's max on this axis
			extent: f32 = axis == 2 ? PLAYER_HEIGHT : PLAYER_RADIUS
			target = b.min[axis] - extent
		} else {
			// the feet are the origin, so the downward extent is zero
			extent: f32 = axis == 2 ? 0 : PLAYER_RADIUS
			target = b.max[axis] + extent
		}

		// Only snap to a face this step could actually have crossed. Standing
		// on a thin floor slab means permanently overlapping it by its
		// thickness, and without this check the tiniest sideways drift -- the
		// 1e-12 that cos(90 degrees) is not -- would snap the player out across
		// the slab's full width instead of leaving them where they are.
		if abs(target - old) > abs(delta) + 1e-4 {
			player.position[axis] = old
		} else {
			player.position[axis] = target
		}
		blocked = true
	}
	return
}

// Horizontal move that tries again from a raised position when something is in
// the way, then settles back down. That single retry is the whole of stair
// climbing.
step_move :: proc(dx, dy: f32) {
	start := player.position

	move_axis(0, dx)
	move_axis(1, dy)
	flat := player.position

	if !player.on_ground do return

	// close enough to the requested move means nothing worth stepping over
	wanted := linalg.length([2]f32{dx, dy})
	got := linalg.length([2]f32{flat.x - start.x, flat.y - start.y})
	if got >= wanted - 0.001 do return

	// retry elevated, but only if there is headroom up there
	player.position = start
	player.position.z += STEP_HEIGHT
	if overlaps_any(player.position) {
		player.position = flat
		return
	}

	move_axis(0, dx)
	move_axis(1, dy)
	move_axis(2, -STEP_HEIGHT)

	stepped := linalg.length(
		[2]f32{player.position.x - start.x, player.position.y - start.y},
	)
	if stepped <= got {
		player.position = flat
	}
}

update_player :: proc(dt: f32) {
	if key_pressed(glfw.KEY_V) {
		player.noclip = !player.noclip
		player.velocity = {}
		log.infof("Noclip {}", player.noclip ? "on" : "off")
	}

	// movement is relative to where you look, but flattened, so looking down
	// does not walk you into the floor
	forward := player.noclip ? camera_forward() : camera_forward_flat()
	right := camera_right()

	wish: [3]f32
	if key_down(glfw.KEY_W) do wish += forward
	if key_down(glfw.KEY_S) do wish -= forward
	if key_down(glfw.KEY_D) do wish += right
	if key_down(glfw.KEY_A) do wish -= right

	if linalg.length(wish) > 0.001 {
		wish = linalg.normalize(wish)
	}

	if player.noclip {
		speed: f32 = NOCLIP_SPEED
		if key_down(glfw.KEY_LEFT_SHIFT) do speed *= SLOW_FACTOR
		if key_down(glfw.KEY_SPACE) do wish.z += 1
		if key_down(glfw.KEY_C) do wish.z -= 1

		player.position += wish * speed * dt
		player.on_ground = false
		return
	}

	speed: f32 = WALK_SPEED
	if key_down(glfw.KEY_LEFT_SHIFT) do speed *= SLOW_FACTOR

	if player.on_ground && key_down(glfw.KEY_SPACE) {
		player.velocity.z = JUMP_SPEED
		player.on_ground = false
	}

	step_move(wish.x * speed * dt, wish.y * speed * dt)

	player.velocity.z -= GRAVITY * dt
	hit := move_axis(2, player.velocity.z * dt)
	if hit {
		// landing clears downward speed, hitting a ceiling clears upward speed
		player.on_ground = player.velocity.z < 0
		player.velocity.z = 0
	} else {
		player.on_ground = false
	}

	// A fall through the world is unrecoverable, so treat it as a respawn.
	if player.position.z < -50 {
		log.warn("Fell out of the world, respawning")
		init_player(world_brushes)
	}
}

// The camera rides at eye height above the feet.
sync_camera_to_player :: proc() {
	camera.position = player.position + {0, 0, EYE_HEIGHT}
}
