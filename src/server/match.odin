package main

import "../game"
import "../protocol"
import "core:log"

// The match state machine. Idle waits for a human; a join fills both teams
// with bots around the humans and starts the mode's opening phase; the mode
// then owns the clock. Game_Mode is the seam other modes plug into: team
// deathmatch runs the default machine below, competitive brings its own tick.

Game_Mode :: struct {
	id:              game.Mode,
	name:            string,
	team_size:       int, // pawns per side; bots fill what humans leave empty
	countdown_s:     f32, // length of the opening phase (.Countdown / .Warmup)
	match_len_s:     f32,
	post_s:          f32,
	respawn_s:       f32,
	// Phases in which the dead come back on their own. TDM respawns during
	// .Live; comp only during .Warmup -- rounds bring everyone back at once.
	respawn_phases:  bit_set[game.Match_Phase],
	drop_in:         bool, // humans may join mid-.Live, displacing a bot
	// Whether joins and leaves rebalance bots on the spot. TDM does; comp
	// keeps its warmup bot-free and backfills at each round start instead.
	fill_on_join:    bool,
	opening_phase:   game.Match_Phase,
	// Scoring: called for every confirmed kill with pawn ids.
	on_kill:         proc(killer, victim: int),
	// The mode's own phase machine; nil runs the default TDM one in match_tick.
	tick:            proc(),
	on_join:         proc(slot: ^Client_Slot),
	// Called before a leaver's pawn is zeroed (comp drops the bomb here).
	on_pawn_removed: proc(pawn_id: int),
}

TDM_MODE := Game_Mode {
	id             = .TDM,
	name           = "team deathmatch",
	team_size      = game.TEAM_SIZE,
	countdown_s    = 3,
	match_len_s    = 60,
	post_s         = 5,
	respawn_s      = 3,
	respawn_phases = {.Live},
	drop_in        = true,
	fill_on_join   = true,
	opening_phase  = .Countdown,
	on_kill        = tdm_on_kill,
}

Match :: struct {
	phase:            game.Match_Phase,
	phase_end_tick:   u32,
	// When the current phase began. A phase change takes a round trip to
	// reach the client, so refusals are only held against it after a grace
	// period measured from here -- see note_fire_block.
	phase_start_tick: u32,
	t_score:          int,
	ct_score:         int,
	// What the last phase message said, kept so a resync repeats it: comp's
	// round number and the last decided round's winner and reason.
	round:            int,
	winner:           u8, // game.Team as u8; game.NO_WINNER = none
	reason:           game.Round_End_Reason,
	mode:             Game_Mode,
}

match: Match

// Pawn ids are one shared pool: a human reserves one for its whole session at
// connect (the accept already names it), bots claim what is left per round.
// An id is held while any non-empty slot names it or the pawn itself is active.
alloc_pawn_id :: proc() -> int {
	for id in 0 ..< game.MAX_PAWNS {
		if sv.gs.pawns[id].active do continue
		held := false
		for &slot in clients {
			if slot.state != .Empty && slot.pawn_id == id {
				held = true
				break
			}
		}
		if !held do return id
	}
	return -1
}

init_match :: proc(mode: game.Mode) {
	switch mode {
	case .TDM:
		match.mode = TDM_MODE
	case .Comp:
		match.mode = COMP_MODE
	}
	match.phase = .Idle
	match.winner = game.NO_WINNER
}

// Seconds until the current phase ends; what the snapshot carries and the
// client's HUD counts down.
match_time_left :: proc() -> f32 {
	if match.phase == .Idle do return 0
	if sv.tick >= match.phase_end_tick do return 0
	return f32(match.phase_end_tick - sv.tick) * game.TICK_DT
}

handle_join :: proc(slot: ^Client_Slot, wished: game.Team) {
	if slot.state == .In_Game {
		// A duplicate Join just gets told where the match stands.
		queue_phase_msg(slot)
		return
	}

	accepting :=
		match.phase == .Idle ||
		match.phase == match.mode.opening_phase ||
		(match.mode.drop_in && match.phase == .Live)
	if !accepting {
		queue_join_deny(slot, .Between_Matches)
		return
	}

	team, ok := balance_team(wished)
	if !ok {
		queue_join_deny(slot, .Teams_Full)
		return
	}

	starting := match.phase == .Idle
	if starting {
		match.t_score = 0
		match.ct_score = 0
	}

	slot.state = .In_Game
	slot.team = team
	slot.loadout = game.default_loadout(team)

	spawn_human(slot)
	if match.mode.fill_on_join do fill_bots()
	if match.mode.on_join != nil do match.mode.on_join(slot)
	// fill_bots may not have run; the newcomer still needs the full roster
	broadcast_roster()

	log.infof(
		"Server: client {} joined {} ({} human(s) in game)",
		client_index(slot),
		team,
		count_humans_in_game(),
	)

	if starting {
		log.infof("Server: match starting -- {}", match.mode.name)
		set_phase(
			match.mode.opening_phase,
			sv.tick + u32(match.mode.countdown_s * game.TICK_RATE),
		)
	} else {
		queue_phase_msg(slot)
	}
}

// The team with fewer humans wins the newcomer; a tie honors the wish. Both
// sides full of humans means no seat, however many bots could yield.
@(private = "file")
balance_team :: proc(wished: game.Team) -> (game.Team, bool) {
	counts: [game.Team]int
	for &slot in clients {
		if slot.state == .In_Game do counts[slot.team] += 1
	}

	team := wished
	if counts[.T] < counts[.CT] do team = .T
	else if counts[.CT] < counts[.T] do team = .CT

	if counts[team] >= match.mode.team_size {
		other: game.Team = team == .T ? .CT : .T
		if counts[other] >= match.mode.team_size do return team, false
		team = other
	}
	return team, true
}

count_humans_in_game :: proc() -> int {
	n := 0
	for &slot in clients {
		if slot.state == .In_Game do n += 1
	}
	return n
}

team_pawn_count :: proc(team: game.Team) -> int {
	n := 0
	for &p in sv.gs.pawns {
		if p.active && p.team == team do n += 1
	}
	return n
}

// Brings both teams to the mode's size: bots fill empty seats, crowded teams
// shed bots first (a drop-in human displaces a bot, never a player). Safe to
// call at any time; a full roster is a no-op.
fill_bots :: proc() {
	for team in game.Team {
		for team_pawn_count(team) > match.mode.team_size {
			if !despawn_one_bot(team) do break
		}
		for team_pawn_count(team) < match.mode.team_size {
			id := alloc_pawn_id()
			if id < 0 {
				log.warn("Server: no free pawn id for a bot, team plays short")
				break
			}
			spawn_bot(id, team)
		}
	}
	log.infof(
		"Server: roster -- {} T pawns, {} CT pawns",
		team_pawn_count(.T),
		team_pawn_count(.CT),
	)
	broadcast_roster()
}

// Prefers a dead bot so a displacement is invisible; any bot failing that.
@(private = "file")
despawn_one_bot :: proc(team: game.Team) -> bool {
	pick := -1
	for &p, i in sv.gs.pawns {
		if !p.active || !p.is_bot || p.team != team do continue
		pick = i
		if !p.alive do break
	}
	if pick < 0 do return false
	sv.gs.pawns[pick] = {}
	brains[pick] = {}
	return true
}

match_tick :: proc() {
	if match.mode.tick != nil {
		match.mode.tick()
		return
	}

	if match.phase == .Idle do return
	if sv.tick < match.phase_end_tick do return

	#partial switch match.phase {
	case .Countdown:
		set_phase(.Live, sv.tick + u32(match.mode.match_len_s * game.TICK_RATE))

	case .Live:
		// Post IS the match-end message; the final scores ride in it.
		set_phase(
			.Post,
			sv.tick + u32(match.mode.post_s * game.TICK_RATE),
			game.NO_WINNER,
			.Match_Over,
		)
		log.infof("Server: match over -- T {} : {} CT", match.t_score, match.ct_score)

	case .Post:
		reset_to_idle()
	}
}

// A human left. Play continues as long as one remains; the last one out ends
// the match on the spot.
match_human_left :: proc() {
	if match.phase == .Idle do return
	if count_humans_in_game() > 0 {
		// Keep the teams even: the leaver's seat goes back to a bot. Comp
		// waits for the next round start instead of spawning one mid-round.
		if match.mode.fill_on_join do fill_bots()
		return
	}
	// A fleet comp server is single-use: everyone leaving (which the match
	// end does on its own -- clients disconnect at Post) retires it and the
	// fleet spawns a fresh one. Dev servers just reset for the next join.
	if match.mode.id == .Comp && hb.enabled {
		begin_shutdown()
		return
	}
	reset_to_idle()
}

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
	match.round = 0
	match.winner = game.NO_WINNER
	match.reason = .None
	log.info("Server: back to idle, waiting for a join")
}

set_phase :: proc(
	phase: game.Match_Phase,
	end_tick: u32,
	winner: u8 = game.NO_WINNER,
	reason: game.Round_End_Reason = .None,
) {
	match.phase = phase
	match.phase_end_tick = end_tick
	match.phase_start_tick = sv.tick
	match.winner = winner
	match.reason = reason
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
			round = u8(clamp(match.round, 0, 255)),
			winner = match.winner,
			reason = match.reason,
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
	// the K/D just moved; keep every scoreboard authoritative
	broadcast_roster()
}

// Names and scores for every active pawn, sent whenever either changes: a
// join, a kill, a drop, a bot claim. Edge-triggered and small, so there is no
// per-tick cost. Connected clients get it too: the team select shows who is
// already in the match.
broadcast_roster :: proc() {
	full := build_roster()
	chunks: [protocol.MAX_ROSTER_CHUNKS]protocol.Roster
	n := protocol.roster_chunk_split(full, chunks[:])
	for &slot in clients {
		if slot.state != .In_Game && slot.state != .Connected do continue
		queue_roster_chunks(&slot, chunks[:n])
	}
}

// The full roster for one client -- a fresh browser right after its accept.
queue_roster :: proc(slot: ^Client_Slot) {
	full := build_roster()
	chunks: [protocol.MAX_ROSTER_CHUNKS]protocol.Roster
	n := protocol.roster_chunk_split(full, chunks[:])
	queue_roster_chunks(slot, chunks[:n])
}

@(private = "file")
build_roster :: proc() -> protocol.Roster {
	roster: protocol.Roster
	for id in 0 ..< game.MAX_PAWNS {
		if !sv.gs.pawns[id].active do continue
		entry := protocol.Roster_Entry {
			pawn_id = u8(id),
			kills   = u8(clamp(sv.gs.pawns[id].kills, 0, 255)),
			deaths  = u8(clamp(sv.gs.pawns[id].deaths, 0, 255)),
		}
		for &slot in clients {
			if slot.state == .In_Game && slot.pawn_id == id {
				entry.name = slot.name
				entry.name_len = slot.name_len
				break
			}
		}
		roster.entries[roster.count] = entry
		roster.count += 1
	}
	return roster
}

@(private = "file")
queue_roster_chunks :: proc(slot: ^Client_Slot, chunks: []protocol.Roster) {
	for chunk in chunks {
		if !protocol.queue_reliable_msg(&slot.conn, .Roster, protocol.write_roster, chunk) {
			log.warnf(
				"Server: reliable window full for client {}, dropping",
				client_index(slot),
			)
			drop_client(slot)
			return
		}
	}
}

@(private = "file")
queue_join_deny :: proc(slot: ^Client_Slot, reason: protocol.Join_Deny_Reason) {
	log.infof("Server: client {} join refused ({})", client_index(slot), reason)
	ok := protocol.queue_reliable_msg(
		&slot.conn,
		.Join_Deny,
		protocol.write_join_deny,
		protocol.Join_Deny_Msg{reason = reason},
	)
	if !ok {
		log.warnf("Server: reliable window full for client {}, dropping", client_index(slot))
		drop_client(slot)
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
