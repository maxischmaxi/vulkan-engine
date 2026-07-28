package main

import "core:log"
import "core:math/linalg"
import "game"
import "physics"

// The client's slice of the shared simulation: one Game_State, with the local
// player living in slot zero. Everything that is a feeling rather than a fact
// -- the damage flash, the hit direction -- stays here, out of the sim.

gs: game.Game_State

// Slot zero is the local player until a server starts assigning ids.
LOCAL_PAWN :: 0

// A pointer rather than a copy, so the rest of the client keeps saying
// `player.health` and means the pawn in the shared state.
player := &gs.pawns[LOCAL_PAWN]

PLAYER_RESPAWN_DELAY :: 3.0

// How long the screen stays red after a hit. Short enough not to obscure the
// return fire, long enough to notice at 64 ticks a second.
DAMAGE_FLASH_TIME :: 0.6

// Feedback the HUD reads: how much red is left, and the world-space heading
// from the player toward whatever last hit them.
Player_Fx :: struct {
	damage_flash: f32,
	damage_dir:   [2]f32,
}

player_fx: Player_Fx

init_player :: proc() {
	game.init_pawn(player, game.SPAWN_POSITION, game.SPAWN_YAW)
	player_fx = {}

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
// both describe the session rather than the life. init_pawn touches neither.
respawn_player :: proc() {
	game.init_pawn(player, game.SPAWN_POSITION, game.SPAWN_YAW)
	player_fx = {}
	init_view()

	refill_all_ammo()
	select_weapon(default_weapon_index())
	intent = {}
}

// `from` is where the damage came from, which is all the HUD needs to point at
// it. The armour math is the shared sim's; the flash and the heading are ours.
damage_player :: proc(amount: int, from: [3]f32) {
	if !player.alive || amount <= 0 do return
	if debug.god_mode do return

	killed := game.damage_pawn(player, amount)
	player_fx.damage_flash = DAMAGE_FLASH_TIME

	// Straight-line heading in the ground plane. A shot from directly above or
	// below leaves the old direction standing, which is better than a zero
	// vector pointing the indicator at nothing.
	delta := [2]f32{from.x - player.body.position.x, from.y - player.body.position.y}
	if linalg.length(delta) > 0.001 {
		player_fx.damage_dir = linalg.normalize(delta)
	}

	if killed {
		player.respawn_in = PLAYER_RESPAWN_DELAY
		log.infof("Eliminated ({} deaths)", player.deaths)
	}
}

// One simulation step. Runs at a fixed rate, so the result does not depend on
// how fast the machine renders. The moving itself is the shared pawn_move's job.
tick_player :: proc(dt: f32) {
	player.prev_position = player.body.position
	player_fx.damage_flash = max(player_fx.damage_flash - dt, 0)

	// Dead players do not move, jump or duck. The camera stays where it fell, so
	// the respawn is the only thing that puts it back.
	if !player.alive {
		player.respawn_in -= dt
		if player.respawn_in <= 0 do respawn_player()
		intent = {}
		return
	}

	if intent.toggle_noclip {
		intent.toggle_noclip = false
		player.noclip = !player.noclip
		player.body.velocity = {}
		log.infof("Noclip {}", player.noclip ? "on" : "off")
	}

	ev := game.pawn_move(&gs, player, build_local_input(), dt)
	view_note_step(ev.stepped)
	if ev.jumped do view_note_airborne()
	if ev.landed do view_note_landing(ev.impact)

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
	view_update(game.clock.frame_dt)

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
	return game.eye_position(player^)
}

// What the camera should be sitting at, before any smoothing.
player_eye_height_target :: proc() -> f32 {
	return game.eye_height_target(player^)
}

// What the speedometer reads, in the units the number is memorable in.
player_speed_units :: proc() -> f32 {
	return physics.horizontal_speed(player.body.velocity) * game.UNITS_PER_METRE
}
