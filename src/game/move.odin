package game

import "../physics"

// How a pawn moves. The equations live in physics/movement.odin, which knows
// nothing about keys or cameras; this is the half that keeps the stance and
// puts the pieces together in the order counter-strike does. It reads a
// Pawn_Input rather than the keyboard, so the server can run it from the wire
// and the client can run it twice -- once to predict, again to reconcile.
//
// The order is not decoration. Jump is resolved before friction, so a jump
// taken on the tick you land costs nothing -- that single line is what makes
// chaining jumps worth doing, and everything else about bunny-hopping follows
// from it.

// One Source unit in metres. Speeds are quoted in units per second throughout,
// because those are the numbers a counter-strike player already knows: 250 is a
// run, 320 is a good hop, anything past 400 took a chain to build.
UNIT :: 0.0254
UNITS_PER_METRE :: 1.0 / UNIT

WALK_SPEED :: 250 * UNIT // 6.35 m/s
SLOW_FACTOR :: 0.52 // holding shift, counter-strike's walk
CROUCH_FACTOR :: 0.34 // ducked
ZOOM_FACTOR :: 0.4 // scoped in, roughly counter-strike's awp walk
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

// One tick's worth of what a player wants. This struct is what goes over the
// wire: the client sends nothing but a stream of these, and the server never
// believes anything else -- which is the whole anti-cheat posture.
Button :: enum u8 {
	Forward,
	Back,
	Left,
	Right,
	Jump, // held
	Jump_Pressed, // the edge, for the buffer -- a press between ticks still lands
	Crouch,
	Slow,
	Fire, // held
	Fire_Pressed, // the edge, for semi-automatics
	Reload,
	Zoom, // held while scoped; slows the walk on both ends of the wire
	Use, // held: plant or defuse, the bomb's one verb
}

Buttons :: bit_set[Button;u16]

Pawn_Input :: struct {
	buttons:     Buttons,
	yaw, pitch:  f32, // degrees; quantized by the wire, so predict with the quantized values
	weapon_slot: i8, // -1 = no switch request
}

// What one tick of movement did to the feet, for the client's eye smoothing.
// The server ignores it.
Move_Events :: struct {
	stepped: f32, // vertical feet displacement from stairs and stance changes
	jumped:  bool,
	landed:  bool,
	impact:  f32, // downward speed at the landing
}

// One simulation step. Applies the orientation, resolves the stance, then runs
// the Source order: jump before friction, friction or air control, clamp,
// step_move, gravity.
pawn_move :: proc(gs: ^Game_State, p: ^Pawn, input: Pawn_Input, dt: f32) -> (ev: Move_Events) {
	p.yaw = input.yaw
	p.pitch = input.pitch

	if .Jump_Pressed in input.buttons {
		p.jump_buffer = JUMP_BUFFER_TIME
	}

	if p.noclip {
		noclip_move(p, input, dt)
		return
	}

	ev = walk_move(gs, p, input, dt)
	p.jump_buffer = max(p.jump_buffer - dt, 0)
	return
}

// The direction the buttons ask for, flattened, plus the speed the stance
// allows.
@(private = "file")
wish_move :: proc(p: ^Pawn, input: Pawn_Input) -> (dir: [3]f32, speed: f32) {
	forward := yaw_forward_flat(p.yaw)
	right := yaw_right(p.yaw)

	if .Forward in input.buttons do dir += forward
	if .Back in input.buttons do dir -= forward
	if .Right in input.buttons do dir += right
	if .Left in input.buttons do dir -= right

	// Normalised, so holding two keys does not walk you diagonally faster than
	// forward. Below the threshold there is no direction to speak of, and the
	// accelerate step will ignore a zero vector anyway.
	length := physics.horizontal_speed(dir)
	if length > 0.001 {
		dir /= length
	}

	speed = WALK_SPEED
	if p.crouching {
		speed *= CROUCH_FACTOR
	} else if .Slow in input.buttons {
		speed *= SLOW_FACTOR
	}
	if .Zoom in input.buttons {
		speed *= ZOOM_FACTOR
	}
	return
}

@(private = "file")
walk_move :: proc(gs: ^Game_State, p: ^Pawn, input: Pawn_Input, dt: f32) -> (ev: Move_Events) {
	ev.stepped += resolve_stance(gs, p, input)

	wish, speed := wish_move(p, input)

	// Before friction, exactly as Source orders it. Leaving the ground on the
	// tick you touched it must not be charged for the contact, or a chain of
	// jumps would bleed speed instead of building it.
	if p.body.on_ground && wants_jump(p^, input) {
		p.body.velocity.z = JUMP_SPEED
		p.body.on_ground = false
		p.jump_buffer = 0
		ev.jumped = true
	}

	if p.body.on_ground {
		physics.apply_friction(&p.body.velocity, GROUND_FRICTION, STOP_SPEED, dt)
		physics.accelerate(&p.body.velocity, wish, speed, GROUND_ACCEL, dt)
	} else {
		physics.air_accelerate(&p.body.velocity, wish, speed, AIR_MAX_WISH_SPEED, AIR_ACCEL, dt)
	}
	physics.clamp_horizontal_speed(&p.body.velocity, MAX_SPEED)

	// The stair retry inside step_move is a teleport: the whole climb happens
	// between these two reads, which is exactly what the eye has to be spared.
	before_z := p.body.position.z
	blocked_x, blocked_y := physics.grid_step_move(
		&p.body,
		&gs.grid,
		p.body.velocity.x * dt,
		p.body.velocity.y * dt,
	)
	// Every surface in the map is axis-aligned, so clearing the stopped
	// component is the whole of sliding along a wall. Leaving it standing would
	// pile up speed against the wall and release all of it on the way off.
	if blocked_x do p.body.velocity.x = 0
	if blocked_y do p.body.velocity.y = 0
	ev.stepped += p.body.position.z - before_z

	// Read before gravity runs, because landing is what clears the speed that
	// says how hard the landing was.
	was_airborne := !p.body.on_ground
	impact := -p.body.velocity.z
	physics.grid_apply_gravity(&p.body, &gs.grid, GRAVITY, dt)
	if was_airborne && p.body.on_ground {
		ev.landed = true
		ev.impact = impact
	}
	return
}

// A press inside the buffer window counts, and so does simply holding the key
// when auto-hop is on.
@(private = "file")
wants_jump :: proc(p: Pawn, input: Pawn_Input) -> bool {
	when AUTO_HOP {
		if .Jump in input.buttons do return true
	}
	return p.jump_buffer > 0
}

// Ducking and standing back up. The mechanics are physics' problem; what
// belongs here is the button, and reporting how far the feet just moved -- the
// mid-air duck shifts the body half a metre in one tick, and a camera bolted
// straight onto that would snap.
@(private = "file")
resolve_stance :: proc(gs: ^Game_State, p: ^Pawn, input: Pawn_Input) -> (stepped: f32) {
	want_crouch := .Crouch in input.buttons

	if want_crouch {
		if p.crouching do return 0
		p.crouching = true
		return physics.duck_hull(&p.body, CROUCH_HEIGHT)
	}

	if !p.crouching do return 0

	moved, ok := physics.grid_stand_hull(&p.body, &gs.grid, PLAYER_HEIGHT)
	if !ok do return 0 // no headroom, so stay ducked

	p.crouching = false
	return moved
}

// Free flight for debugging. Jump rises, crouch sinks; there is nothing to
// duck under while passing through walls.
@(private = "file")
noclip_move :: proc(p: ^Pawn, input: Pawn_Input, dt: f32) {
	if p.crouching {
		p.crouching = false
		p.body.height = PLAYER_HEIGHT
	}

	forward := view_forward(p.yaw, p.pitch)
	right := yaw_right(p.yaw)

	wish: [3]f32
	if .Forward in input.buttons do wish += forward
	if .Back in input.buttons do wish -= forward
	if .Right in input.buttons do wish += right
	if .Left in input.buttons do wish -= right
	if .Jump in input.buttons do wish.z += 1
	if .Crouch in input.buttons do wish.z -= 1

	speed: f32 = NOCLIP_SPEED
	if .Slow in input.buttons do speed *= SLOW_FACTOR

	p.body.position += wish * speed * dt
	p.body.on_ground = false
	p.jump_buffer = 0
}
