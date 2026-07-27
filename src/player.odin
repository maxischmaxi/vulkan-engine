package main

import "core:log"
import "core:math/linalg"
import "physics"

// Roughly the counter-strike player: 32x32x72 units at 0.0254 m per unit.
PLAYER_RADIUS :: 0.3
PLAYER_HEIGHT :: 1.8
EYE_HEIGHT :: 1.65

// The ducked player: half the standing hull, eyes just under its top. Both
// numbers are the counter-strike ratios (36 and 28 of 72 units) applied to the
// height above.
CROUCH_HEIGHT :: 0.9
CROUCH_EYE_HEIGHT :: 0.75

// Half the hull is lost on ducking, and in mid-air half of that comes off the
// feet -- see physics.duck_hull. Quoted here because it is a number the map is
// laid out against, not an implementation detail.
AIR_DUCK_LIFT :: (PLAYER_HEIGHT - CROUCH_HEIGHT) * 0.5

// Source calls this sv_stepsize (18 units). Anything shorter than this gets
// walked over without a jump, which is what makes the stairs feel like ramps.
// It also bounds the mid-air duck's lift, since the camera unwinds both through
// the same smoothing.
STEP_HEIGHT :: 0.45
#assert(AIR_DUCK_LIFT <= STEP_HEIGHT)

PLAYER_MAX_HEALTH :: 100
PLAYER_MAX_ARMOR :: 100

// Counter-strike's kevlar: half of what gets through goes into the vest instead
// of the player, and the vest wears down by the amount it absorbed.
ARMOR_ABSORB :: 0.5

PLAYER_RESPAWN_DELAY :: 3.0

// How long the screen stays red after a hit. Short enough not to obscure the
// return fire, long enough to notice at 64 ticks a second.
DAMAGE_FLASH_TIME :: 0.6

Player :: struct {
	body:          physics.Body,
	prev_position: [3]f32, // start of the current tick, for render interpolation
	crouching:     bool,
	noclip:        bool,
	health:        int,
	armor:         int,
	alive:         bool,
	respawn_in:    f32,
	// Feedback the HUD reads: how much red is left, and the world-space heading
	// from the player toward whatever last hit them.
	damage_flash:  f32,
	damage_dir:    [2]f32,
	kills:         int,
	deaths:        int,
}

player: Player

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
	player.health = PLAYER_MAX_HEALTH
	player.armor = PLAYER_MAX_ARMOR
	player.alive = true
	player.respawn_in = 0
	player.damage_flash = 0
	player.damage_dir = {}

	// after the stance is settled, so the eye starts where it belongs instead of
	// sliding into place on the first frame
	init_view()
}

// Puts the player somewhere else outright. The view is reset with them, because
// every smoothing the camera does describes a movement, and this is not one.
teleport_player :: proc(position: [3]f32) {
	player.body.position = position
	player.body.velocity = {}
	player.body.on_ground = false
	player.prev_position = position
	init_view()
}

// Back into the fight with a full loadout. Noclip and the score survive, because
// both describe the session rather than the life.
respawn_player :: proc() {
	noclip := player.noclip
	init_player()
	player.noclip = noclip

	refill_all_ammo()
	select_weapon(weapon_in_slot(0))
	player_intent = {}
}

// `from` is where the damage came from, which is all the HUD needs to point at
// it. Armour eats half of what is left after it, up to what the vest has.
damage_player :: proc(amount: int, from: [3]f32) {
	if !player.alive || amount <= 0 do return
	if debug.god_mode do return

	taken := amount
	if player.armor > 0 {
		absorbed := min(player.armor, int(f32(taken) * ARMOR_ABSORB))
		player.armor -= absorbed
		taken -= absorbed
	}

	player.health -= taken
	player.damage_flash = DAMAGE_FLASH_TIME

	// Straight-line heading in the ground plane. A shot from directly above or
	// below leaves the old direction standing, which is better than a zero
	// vector pointing the indicator at nothing.
	delta := [2]f32{from.x - player.body.position.x, from.y - player.body.position.y}
	if linalg.length(delta) > 0.001 {
		player.damage_dir = linalg.normalize(delta)
	}

	if player.health <= 0 do kill_player()
}

kill_player :: proc() {
	if !player.alive do return

	player.health = 0
	player.alive = false
	player.deaths += 1
	player.respawn_in = PLAYER_RESPAWN_DELAY
	player.body.velocity = {}
	log.infof("Eliminated ({} deaths)", player.deaths)
}

// What the camera should be sitting at, before any smoothing.
player_eye_height_target :: proc() -> f32 {
	return player.crouching ? CROUCH_EYE_HEIGHT : EYE_HEIGHT
}

// One simulation step. Runs at a fixed rate, so the result does not depend on
// how fast the machine renders. The moving itself is movement.odin's job.
tick_player :: proc(dt: f32) {
	player.prev_position = player.body.position
	player.damage_flash = max(player.damage_flash - dt, 0)

	// Dead players do not move, jump or duck. The camera stays where it fell, so
	// the respawn is the only thing that puts it back.
	if !player.alive {
		player.respawn_in -= dt
		if player.respawn_in <= 0 do respawn_player()
		player_intent = {}
		return
	}

	move_player(dt)

	// A fall through the world is unrecoverable, so treat it as a respawn.
	if player.body.position.z < -50 {
		log.warn("Fell out of the world, respawning")
		respawn_player()
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

// The eye in the simulation's own frame. player_eye reads the camera, which is
// only placed once the tick loop is done -- anything running inside a tick has
// to ask here instead, and ducking behind cover has to lower this or it counts
// for nothing.
player_tick_eye :: proc() -> [3]f32 {
	return player.body.position + {0, 0, player_eye_height_target()}
}
