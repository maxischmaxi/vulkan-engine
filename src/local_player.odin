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

// How many hit directions the indicator can show at once.
DAMAGE_SLOTS :: 4

// cos 30 degrees: a repeat hit within this cone refreshes its slot instead of
// spawning a duplicate.
DAMAGE_MERGE_COS :: 0.866

Damage_Hit :: struct {
	dir:       [2]f32, // world-space unit vector, victim toward attacker
	time_left: f32,
	strength:  f32, // peak intensity 0..1, from the damage amount
}

// Feedback the damage indicator reads: up to DAMAGE_SLOTS directional hits,
// plus a directionless flash for hits whose heading is unknown (lost damage
// datagram, shot from directly above or below).
Player_Fx :: struct {
	hits:  [DAMAGE_SLOTS]Damage_Hit,
	flash: f32,
}

player_fx: Player_Fx

// 10 damage ~ 0.65, 25 ~ 0.88, 40+ saturates. Tunable.
@(private = "file")
hit_strength :: proc(amount: int) -> f32 {
	return clamp(0.5 + f32(amount) / 66.0, 0.5, 1.0)
}

// The one entry point for every damage cue, local or networked. `world_delta`
// points from the victim toward the attacker in the ground plane; a degenerate
// delta becomes the directionless flash.
register_hit :: proc(world_delta: [2]f32, amount: int) {
	if amount <= 0 do return
	if linalg.length(world_delta) < 0.001 {
		player_fx.flash = DAMAGE_FLASH_TIME
		return
	}
	dir := linalg.normalize(world_delta)
	strength := hit_strength(amount)

	// The same attacker hitting again refreshes their slot. Newest heading
	// wins -- the attacker may be strafing.
	for &hit in player_fx.hits {
		if hit.time_left <= 0 do continue
		if linalg.dot(hit.dir, dir) >= DAMAGE_MERGE_COS {
			hit.dir = dir
			hit.time_left = DAMAGE_FLASH_TIME
			hit.strength = max(hit.strength, strength)
			return
		}
	}
	// A free slot if one exists, else evict the most faded.
	best := &player_fx.hits[0]
	for &hit in player_fx.hits[1:] {
		if hit.time_left < best.time_left do best = &hit
	}
	best^ = {
		dir       = dir,
		time_left = DAMAGE_FLASH_TIME,
		strength  = strength,
	}
}

decay_player_fx :: proc(dt: f32) {
	for &hit in player_fx.hits do hit.time_left = max(hit.time_left - dt, 0)
	player_fx.flash = max(player_fx.flash - dt, 0)
}

init_player :: proc() {
	game.init_pawn(player, game.SPAWN_POSITION, game.SPAWN_YAW)
	// The session's starting kit; online the server's word replaces it, offline
	// it is simply what respawns hand back.
	player.loadout = seed_loadout()
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

	reset_zoom()
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
	register_hit({from.x - player.body.position.x, from.y - player.body.position.y}, amount)

	if killed {
		player.respawn_in = PLAYER_RESPAWN_DELAY
		log.infof("Eliminated ({} deaths)", player.deaths)
	}
}

// One simulation step. Runs at a fixed rate, so the result does not depend on
// how fast the machine renders. The moving itself is the shared pawn_move's job.
tick_player :: proc(dt: f32) {
	player.prev_position = player.body.position
	decay_player_fx(dt)

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
	if ev.jumped {
		audio_emit({kind = .Jump, local = true})
	}
	if ev.landed {
		view_note_landing(ev.impact)
		if ev.impact >= LAND_MIN_IMPACT {
			audio_emit({kind = .Land, local = true, intensity = min(ev.impact / LAND_SPEED_FULL, 1)})
		}
	}

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
	camera.position = {
		position.x,
		position.y,
		view_camera_z(position.z, player.body.on_ground, game.clock.frame_dt),
	}

	if cli.view_log {
		log.infof(
			"VIEW: raw={:.4f} smooth={:.4f} cam={:.4f} ground={} alpha={:.2f}",
			position.z,
			view.smooth_z,
			camera.position.z,
			player.body.on_ground,
			alpha,
		)
	}
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
