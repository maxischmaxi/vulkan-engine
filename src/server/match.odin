package main

import "../game"
import "../protocol"
import "core:log"

// The match state machine. Idle waits for a human; a join spawns both teams
// and starts the countdown; Live runs the clock; Post shows the score and
// resets. Game_Mode is the seam other modes plug into later: team deathmatch
// is the first instance, not a special case.

Game_Mode :: struct {
	name:        string,
	bot_count:   int, // the OPPOSING team is filled with this many bots
	countdown_s: f32,
	match_len_s: f32,
	post_s:      f32,
	respawn_s:   f32,
	// Scoring: called for every confirmed kill with pawn ids.
	on_kill:     proc(killer, victim: int),
}

TDM_MODE := Game_Mode {
	name        = "team deathmatch",
	bot_count   = 5,
	countdown_s = 3,
	match_len_s = 60,
	post_s      = 5,
	respawn_s   = 3,
	on_kill     = tdm_on_kill,
}

Match :: struct {
	phase:            game.Match_Phase,
	phase_end_tick:   u32,
	// When the current phase began. A phase change takes a round trip to
	// reach the client, so refusals are only held against it after a grace
	// period measured from here -- see note_fire_block.
	phase_start_tick: u32,
	human_team:       game.Team,
	t_score:          int,
	ct_score:         int,
	mode:             Game_Mode,
}

match: Match

// Bots occupy the pawn slots behind the client slots.
BOT_PAWN_FIRST :: MAX_CLIENTS
#assert(BOT_PAWN_FIRST + 5 <= game.MAX_PAWNS)

init_match :: proc() {
	match.mode = TDM_MODE
	match.phase = .Idle
}

// Seconds until the current phase ends; what the snapshot carries and the
// client's HUD counts down.
match_time_left :: proc() -> f32 {
	if match.phase == .Idle do return 0
	if sv.tick >= match.phase_end_tick do return 0
	return f32(match.phase_end_tick - sv.tick) * game.TICK_DT
}

handle_join :: proc(slot: ^Client_Slot, team: game.Team) {
	if match.phase != .Idle {
		// A second join mid-match (or a duplicate) just gets told where the
		// match stands; with one human this is a resync, not a rejection.
		queue_phase_msg(slot)
		return
	}

	slot.state = .In_Game
	slot.team = team
	slot.loadout = game.default_loadout(team)
	match.human_team = team
	match.t_score = 0
	match.ct_score = 0

	spawn_human(slot)

	enemy: game.Team = team == .T ? .CT : .T
	for i in 0 ..< match.mode.bot_count {
		spawn_bot(BOT_PAWN_FIRST + i, enemy)
	}

	log.infof(
		"Server: match starting -- human on {}, {} bots on {}",
		team,
		match.mode.bot_count,
		enemy,
	)
	set_phase(.Countdown, sv.tick + u32(match.mode.countdown_s * game.TICK_RATE))
}

match_tick :: proc() {
	if match.phase == .Idle do return
	if sv.tick < match.phase_end_tick do return

	#partial switch match.phase {
	case .Countdown:
		set_phase(.Live, sv.tick + u32(match.mode.match_len_s * game.TICK_RATE))

	case .Live:
		// Post IS the match-end message; the final scores ride in it.
		set_phase(.Post, sv.tick + u32(match.mode.post_s * game.TICK_RATE))
		log.infof("Server: match over -- T {} : {} CT", match.t_score, match.ct_score)

	case .Post:
		reset_to_idle()
	}
}

// The human vanished mid-anything: nobody is left to play, so the match ends
// on the spot.
match_human_left :: proc() {
	if match.phase == .Idle do return
	reset_to_idle()
}

@(private = "file")
reset_to_idle :: proc() {
	for &p in sv.gs.pawns {
		p = {}
	}
	for &slot in clients {
		if slot.state == .In_Game do slot.state = .Connected
	}
	match.phase = .Idle
	match.phase_end_tick = 0
	match.phase_start_tick = sv.tick
	log.info("Server: back to idle, waiting for a join")
}

@(private = "file")
set_phase :: proc(phase: game.Match_Phase, end_tick: u32) {
	match.phase = phase
	match.phase_end_tick = end_tick
	match.phase_start_tick = sv.tick
	for &slot in clients {
		if slot.state != .In_Game do continue
		// One warning per phase per client, not one per tick.
		slot.fire_denied_logged = false
		queue_phase_msg(&slot)
	}
}

@(private = "file")
queue_phase_msg :: proc(slot: ^Client_Slot) {
	ok := protocol.queue_reliable_msg(
		&slot.conn,
		.Match_Phase,
		protocol.write_match_phase,
		protocol.Match_Phase_Msg {
			phase = match.phase,
			param_tick = match.phase_end_tick,
			t_score = u8(clamp(match.t_score, 0, 255)),
			ct_score = u8(clamp(match.ct_score, 0, 255)),
		},
	)
	if !ok {
		log.warnf("Server: reliable window full for client {}, dropping", client_index(slot))
		drop_client(slot)
	}
}

// Every confirmed kill funnels through here: scoring, the kill feed, the
// victim's respawn timer.
on_pawn_killed :: proc(killer, victim: int) {
	sv.gs.pawns[victim].respawn_in = match.mode.respawn_s

	if match.mode.on_kill != nil do match.mode.on_kill(killer, victim)

	kill := protocol.Kill {
		killer = killer >= 0 ? u8(killer) : 0xFF,
		victim = u8(victim),
		weapon = killer >= 0 ? u8(sv.gs.pawns[killer].weapon.index) : 0,
	}
	for &slot in clients {
		if slot.state != .In_Game do continue
		if !protocol.queue_reliable_msg(&slot.conn, .Kill, protocol.write_kill, kill) {
			drop_client(&slot)
		}
	}
}

@(private = "file")
tdm_on_kill :: proc(killer, victim: int) {
	if killer < 0 do return // the world scores nothing
	kt := sv.gs.pawns[killer].team
	vt := sv.gs.pawns[victim].team
	if kt == vt do return // no points for team kills, if they ever happen

	if kt == .T {
		match.t_score += 1
	} else {
		match.ct_score += 1
	}
}
