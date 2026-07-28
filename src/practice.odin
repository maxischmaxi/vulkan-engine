package main

import "core:log"
import "game"

// The practice range: the bench's local simulation with a real player at the
// controls. The targets share the bench bots' pawn slots and brains -- the two
// modes never overlap because the benchmark skips the menu entirely.

PRACTICE_BOT_COUNT :: 8
#assert(PRACTICE_BOT_COUNT <= BOT_COUNT)

// Long enough to register the kill before the target is back, Valorant-style.
PRACTICE_BOT_RESPAWN :: f32(3.0)

practice_active :: proc() -> bool {
	return scene.current == .Practice
}

// The predicate for every site that branches on who simulates the world: the
// bench and the range both run the local pawns instead of server snapshots.
local_sim_active :: proc() -> bool {
	return bench_active() || practice_active()
}

// The menu's PRACTICE button. The connection is mandatory: the server has to
// know the player is on the range before the scene may switch, so this goes
// through the same Connecting screen as a match.
start_practice :: proc() {
	scene.practice_pending = true
	scene.chosen_team = .CT // neutral default; the range ignores teams
	enter_scene(.Connecting)
}

// The .Practice side of enter_scene, once the server has accepted. Mirrors
// reset_match, then moves the player into the booth and wakes the targets.
practice_enter :: proc() {
	init_player()
	init_weapons()
	buy_reset(player.loadout)
	clear_decals()

	for i in 1 ..< game.MAX_PAWNS {
		gs.pawns[i].active = false
		gs.pawns[i].alive = false
	}

	teleport_player(game.PRACTICE_PLAYER_SPAWN)
	player.yaw = game.PRACTICE_SPAWN_YAW
	camera.yaw = game.PRACTICE_SPAWN_YAW
	camera.pitch = 0

	verify_practice_areas()
	for i in 0 ..< PRACTICE_BOT_COUNT {
		practice_respawn_bot(i)
	}

	grab_cursor(true)
	log.infof("Practice: {} targets on the range", PRACTICE_BOT_COUNT)
}

// One band per slot, rotating, so near, mid and far stay populated no matter
// which targets are down.
@(private = "file")
practice_band :: proc(index: int) -> []game.Spawn_Area {
	first := index % len(game.PRACTICE_BOT_AREAS)
	return game.PRACTICE_BOT_AREAS[first:first + 1]
}

practice_respawn_bot :: proc(index: int) {
	respawn_bot(index, practice_band(index))
}

// The practice tick. No combat call anywhere -- targets wander, nothing more.
tick_practice :: proc(dt: f32) {
	// The booth is not escape-proof geometry; this guard is the confinement.
	// It also catches a respawn, which init_pawn puts back at T-spawn.
	if player.alive && !game.practice_inside_bounds(player.body.position) {
		teleport_player(game.PRACTICE_PLAYER_SPAWN)
	}

	for i in 0 ..< PRACTICE_BOT_COUNT {
		pawn := bot_pawn(i)
		brain := &brains[i]

		if !pawn.alive {
			pawn.respawn_in -= dt
			if pawn.respawn_in <= 0 do practice_respawn_bot(i)
			continue
		}

		brain.retarget_in -= dt
		if brain.retarget_in <= 0 do pick_bot_direction(brain)
		bot_wander_step(pawn, brain, dt, engaged = false)

		if pawn.body.position.z < -5 do kill_bot(i, respawn_delay = 0.5)
	}
}

// The local shot trace's damage hook, shared with the bench; the range keeps
// its targets down longer than the benchmark does.
local_damage_bot :: proc(index: int, amount: int) -> bool {
	killed := damage_bot(index, amount)
	if killed && practice_active() {
		bot_pawn(index).respawn_in = PRACTICE_BOT_RESPAWN
	}
	return killed
}
