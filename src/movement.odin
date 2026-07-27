package main

import "core:log"
import "physics"
import "vendor:glfw"

// How the player moves. The equations live in physics/movement.odin, which knows
// nothing about keys or cameras; this is the half that reads the keyboard, keeps
// the stance, and puts the two together in the order counter-strike does.
//
// The order is not decoration. Jump is resolved before friction, so a jump taken
// on the tick you land costs nothing -- that single line is what makes chaining
// jumps worth doing, and everything else about bunny-hopping follows from it.

// One Source unit in metres. Speeds are quoted in units per second throughout,
// because those are the numbers a counter-strike player already knows: 250 is a
// run, 320 is a good hop, anything past 400 took a chain to build.
UNIT :: 0.0254
UNITS_PER_METRE :: 1.0 / UNIT

WALK_SPEED :: 250 * UNIT // 6.35 m/s
SLOW_FACTOR :: 0.52 // holding shift, counter-strike's walk
CROUCH_FACTOR :: 0.34 // ducked
NOCLIP_SPEED :: 22.0

GRAVITY :: 800 * UNIT // 20.3 m/s^2

// Clears 1.38 m standing, and 1.83 m with the mid-air duck's lift on top. The
// map is built to those two numbers: ledges up to 1.3 m are a step on the way
// somewhere, 1.4 to 1.8 m are a crouch-jump, and anything higher wants a boost.
JUMP_SPEED :: 7.5

// sv_friction, sv_stopspeed, sv_accelerate. Friction is what a stop feels like;
// acceleration is what a start feels like, and 5.5 puts a standing player at
// full running speed in about a fifth of a second.
GROUND_FRICTION :: 5.2
STOP_SPEED :: 75 * UNIT
GROUND_ACCEL :: 5.5

// sv_airaccelerate and sv_air_max_wishspeed. Thirty units a second is a walking
// pace, and it is all the air gives you along the way you are already going --
// which is the point. Turn side-on to your own velocity and that budget is spent
// on the perpendicular instead, where nothing is measuring it.
AIR_ACCEL :: 12.0
AIR_MAX_WISH_SPEED :: 30 * UNIT

// sv_maxvelocity. Not a gameplay limit -- a perfectly chained hop has no ceiling
// of its own, and collision costs grow with every metre travelled in one tick.
MAX_SPEED :: 3500 * UNIT

// A jump pressed this long before landing still fires on the tick you land. At
// 64 ticks a second, hitting the one frame between touching down and pushing off
// is otherwise a coin flip, and the whole skill would be in the coin.
JUMP_BUFFER_TIME :: 0.15

// Holding the key re-jumps on its own (sv_autobunnyhopping). Chaining is then
// free and the difficulty moves entirely into the strafing, which is the part
// worth being good at. Flip it off for counter-strike's own answer, where every
// hop has to be timed by hand -- the buffer above is sized to make that fair.
AUTO_HOP :: true

// Edge-triggered input, buffered between ticks. A key pressed and released
// inside one frame still has to reach the simulation, which polling at tick time
// would miss.
Player_Intent :: struct {
	jump_buffer:   f32, // seconds of credit left on the last jump press
	toggle_noclip: bool,
}

player_intent: Player_Intent

// Called once per frame, before the tick loop.
gather_player_intent :: proc() {
	if key_pressed(glfw.KEY_V) do player_intent.toggle_noclip = true
	if key_pressed(glfw.KEY_SPACE) do player_intent.jump_buffer = JUMP_BUFFER_TIME
}

// One simulation step of movement. Everything that is not the body -- health,
// respawning, the damage indicator -- is tick_player's business.
move_player :: proc(dt: f32) {
	if player_intent.toggle_noclip {
		player_intent.toggle_noclip = false
		player.noclip = !player.noclip
		player.body.velocity = {}
		log.infof("Noclip {}", player.noclip ? "on" : "off")
	}

	if player.noclip {
		noclip_move(dt)
		return
	}
	walk_move(dt)

	player_intent.jump_buffer = max(player_intent.jump_buffer - dt, 0)
}

// The direction the keys ask for, flattened, plus the speed that stance allows.
@(private = "file")
wish_move :: proc() -> (dir: [3]f32, speed: f32) {
	forward := camera_forward_flat()
	right := camera_right()

	if key_down(glfw.KEY_W) do dir += forward
	if key_down(glfw.KEY_S) do dir -= forward
	if key_down(glfw.KEY_D) do dir += right
	if key_down(glfw.KEY_A) do dir -= right

	// Normalised, so holding two keys does not walk you diagonally faster than
	// forward. Below the threshold there is no direction to speak of, and the
	// accelerate step will ignore a zero vector anyway.
	length := physics.horizontal_speed(dir)
	if length > 0.001 {
		dir /= length
	}

	speed = WALK_SPEED
	if player.crouching {
		speed *= CROUCH_FACTOR
	} else if key_down(glfw.KEY_LEFT_SHIFT) {
		speed *= SLOW_FACTOR
	}
	return
}

@(private = "file")
walk_move :: proc(dt: f32) {
	resolve_stance()

	wish, speed := wish_move()

	// Before friction, exactly as Source orders it. Leaving the ground on the
	// tick you touched it must not be charged for the contact, or a chain of
	// jumps would bleed speed instead of building it.
	if player.body.on_ground && wants_jump() {
		player.body.velocity.z = JUMP_SPEED
		player.body.on_ground = false
		player_intent.jump_buffer = 0
		view_note_airborne()
	}

	if player.body.on_ground {
		physics.apply_friction(&player.body.velocity, GROUND_FRICTION, STOP_SPEED, dt)
		physics.accelerate(&player.body.velocity, wish, speed, GROUND_ACCEL, dt)
	} else {
		physics.air_accelerate(
			&player.body.velocity,
			wish,
			speed,
			AIR_MAX_WISH_SPEED,
			AIR_ACCEL,
			dt,
		)
	}
	physics.clamp_horizontal_speed(&player.body.velocity, MAX_SPEED)

	// The stair retry inside step_move is a teleport: the whole climb happens
	// between these two reads, which is exactly what the eye has to be spared.
	before_z := player.body.position.z
	blocked_x, blocked_y := physics.step_move(
		&player.body,
		world_collision,
		player.body.velocity.x * dt,
		player.body.velocity.y * dt,
	)
	// Every surface in the map is axis-aligned, so clearing the stopped
	// component is the whole of sliding along a wall. Leaving it standing would
	// pile up speed against the wall and release all of it on the way off.
	if blocked_x do player.body.velocity.x = 0
	if blocked_y do player.body.velocity.y = 0
	view_note_step(player.body.position.z - before_z)

	// Read before gravity runs, because landing is what clears the speed that
	// says how hard the landing was.
	was_airborne := !player.body.on_ground
	impact := -player.body.velocity.z
	physics.apply_gravity(&player.body, world_collision, GRAVITY, dt)
	if was_airborne && player.body.on_ground {
		view_note_landing(impact)
	}
}

// A press inside the buffer window counts, and so does simply holding the key
// when auto-hop is on.
@(private = "file")
wants_jump :: proc() -> bool {
	when AUTO_HOP {
		if key_down(glfw.KEY_SPACE) do return true
	}
	return player_intent.jump_buffer > 0
}

// Ducking and standing back up. The mechanics are physics' problem; what belongs
// here is the key, and telling the view how far the feet just moved -- the
// mid-air duck shifts the body half a metre in one tick, and a camera bolted
// straight onto that would snap.
@(private = "file")
resolve_stance :: proc() {
	want_crouch := key_down(glfw.KEY_LEFT_CONTROL)

	if want_crouch {
		if player.crouching do return
		player.crouching = true
		view_note_step(physics.duck_hull(&player.body, CROUCH_HEIGHT))
		return
	}

	if !player.crouching do return

	moved, ok := physics.stand_hull(&player.body, world_collision, PLAYER_HEIGHT)
	if !ok do return // no headroom, so stay ducked

	player.crouching = false
	view_note_step(moved)
}

@(private = "file")
noclip_move :: proc(dt: f32) {
	// nothing to duck under while passing through walls
	if player.crouching {
		player.crouching = false
		player.body.height = PLAYER_HEIGHT
	}

	forward := camera_forward()
	right := camera_right()

	wish: [3]f32
	if key_down(glfw.KEY_W) do wish += forward
	if key_down(glfw.KEY_S) do wish -= forward
	if key_down(glfw.KEY_D) do wish += right
	if key_down(glfw.KEY_A) do wish -= right
	if key_down(glfw.KEY_SPACE) do wish.z += 1
	if key_down(glfw.KEY_C) do wish.z -= 1

	speed: f32 = NOCLIP_SPEED
	if key_down(glfw.KEY_LEFT_SHIFT) do speed *= SLOW_FACTOR

	player.body.position += wish * speed * dt
	player.body.on_ground = false
	player_intent.jump_buffer = 0
}

// What the speedometer reads, in the units the number is memorable in.
player_speed_units :: proc() -> f32 {
	return physics.horizontal_speed(player.body.velocity) * UNITS_PER_METRE
}
