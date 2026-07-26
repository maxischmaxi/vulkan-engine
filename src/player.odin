package main

import "core:log"
import "core:math/linalg"
import "physics"
import "vendor:glfw"

// Roughly the counter-strike player: 32x32x72 units at 0.0254 m per unit.
PLAYER_RADIUS :: 0.3
PLAYER_HEIGHT :: 1.8
EYE_HEIGHT :: 1.65

// The ducked player: half the standing hull, eyes just under its top. Both
// numbers are the counter-strike ratios (36 and 28 of 72 units) applied to the
// height above.
CROUCH_HEIGHT :: 0.9
CROUCH_EYE_HEIGHT :: 0.75

WALK_SPEED :: 6.4 // 250 units/s
SLOW_FACTOR :: 0.45
CROUCH_FACTOR :: 0.34 // ducked speed, as in counter-strike
NOCLIP_SPEED :: 22.0

GRAVITY :: 18.0
JUMP_SPEED :: 5.0 // clears about 0.7 m

// Source calls this sv_stepsize (18 units). Anything shorter than this gets
// walked over without a jump, which is what makes the stairs feel like ramps.
STEP_HEIGHT :: 0.45

Player :: struct {
	body:          physics.Body,
	prev_position: [3]f32, // start of the current tick, for render interpolation
	crouching:     bool,
	noclip:        bool,
}

// Edge-triggered input, buffered between ticks. A key pressed and released
// inside one frame still has to reach the simulation, which polling at tick time
// would miss.
Player_Intent :: struct {
	jump:          bool,
	toggle_noclip: bool,
}

player: Player
player_intent: Player_Intent

init_player :: proc() {
	player.body = physics.Body {
		position = SPAWN_POSITION,
		radius   = PLAYER_RADIUS,
		height   = PLAYER_HEIGHT,
		step     = STEP_HEIGHT,
	}
	player.prev_position = SPAWN_POSITION
	player.crouching = false
	player.noclip = false

	// after the stance is settled, so the eye starts where it belongs instead of
	// sliding into place on the first frame
	init_view()
}

// What the camera should be sitting at, before any smoothing.
player_eye_height_target :: proc() -> f32 {
	return player.crouching ? CROUCH_EYE_HEIGHT : EYE_HEIGHT
}

// Ducking shrinks the hull from the top, which costs nothing because the body
// origin is at the feet. Standing back up does: it needs the headroom, and
// without the test you rise straight through a ceiling.
resolve_crouch :: proc() {
	if key_down(glfw.KEY_LEFT_CONTROL) {
		player.crouching = true
		player.body.height = CROUCH_HEIGHT
		return
	}
	if !player.crouching do return

	standing := player.body
	standing.height = PLAYER_HEIGHT
	if physics.overlaps_any(physics.body_aabb(standing), world_collision) do return

	player.crouching = false
	player.body.height = PLAYER_HEIGHT
}

// Called once per frame, before the tick loop.
gather_player_intent :: proc() {
	if key_pressed(glfw.KEY_V) do player_intent.toggle_noclip = true
	if key_pressed(glfw.KEY_SPACE) do player_intent.jump = true
}

// One simulation step. Runs at a fixed rate, so the result does not depend on
// how fast the machine renders.
tick_player :: proc(dt: f32) {
	player.prev_position = player.body.position

	if player_intent.toggle_noclip {
		player_intent.toggle_noclip = false
		player.noclip = !player.noclip
		player.body.velocity = {}
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
		// nothing to duck under while passing through walls
		player.crouching = false
		player.body.height = PLAYER_HEIGHT

		speed: f32 = NOCLIP_SPEED
		if key_down(glfw.KEY_LEFT_SHIFT) do speed *= SLOW_FACTOR
		if key_down(glfw.KEY_SPACE) do wish.z += 1
		if key_down(glfw.KEY_C) do wish.z -= 1

		player.body.position += wish * speed * dt
		player.body.on_ground = false
		player_intent.jump = false
		return
	}

	resolve_crouch()

	speed: f32 = WALK_SPEED
	if player.crouching {
		speed *= CROUCH_FACTOR
	} else if key_down(glfw.KEY_LEFT_SHIFT) {
		speed *= SLOW_FACTOR
	}

	if player.body.on_ground && player_intent.jump {
		player.body.velocity.z = JUMP_SPEED
		player.body.on_ground = false
		view_note_airborne()
	}
	player_intent.jump = false

	// The stair retry inside step_move is a teleport: the whole climb happens
	// between these two reads, which is exactly what the eye has to be spared.
	before_z := player.body.position.z
	physics.step_move(&player.body, world_collision, wish.x * speed * dt, wish.y * speed * dt)
	view_note_step(player.body.position.z - before_z)

	// Read before gravity runs, because landing is what clears the speed that
	// says how hard the landing was.
	was_airborne := !player.body.on_ground
	impact := -player.body.velocity.z
	physics.apply_gravity(&player.body, world_collision, GRAVITY, dt)
	if was_airborne && player.body.on_ground {
		view_note_landing(impact)
	}

	// A fall through the world is unrecoverable, so treat it as a respawn.
	if player.body.position.z < -50 {
		log.warn("Fell out of the world, respawning")
		init_player()
	}
}

// Where the player is drawn this frame: between the last two simulation states.
// The camera rides at eye height above the feet.
sync_camera_to_player :: proc(alpha: f32) {
	// Advanced with the frame rather than the tick. Smoothing that only moved
	// 64 times a second would be as coarse as the steps it is smoothing out.
	view_update(clock.frame_dt)

	position := linalg.lerp(player.prev_position, player.body.position, alpha)
	camera.position = position + {0, 0, view_eye_offset()}
}

// The eye, which is where shots start from.
player_eye :: proc() -> [3]f32 {
	return camera.position
}
