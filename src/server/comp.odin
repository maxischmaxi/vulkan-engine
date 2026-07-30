package main

import "../game"
import "core:log"

// Competitive: bomb defusal in rounds, MR12. This file owns the round state
// machine -- warmup, freeze, live, round end, halftime, match end -- and the
// per-round resets. match.odin's set_phase does the broadcasting; the bomb
// (server/bomb.odin) and the economy (server/economy.odin) hook in behind
// their own files.
//
// Sequence: Idle -> Warmup -> [Freeze -> Live -> (Bomb)? -> Round_End] x N,
// Halftime after round 12, Post at 13 wins or 12:12.

COMP_WARMUP_S :: 60.0
COMP_FREEZE_S :: 15.0
COMP_ROUND_S :: 115.0 // 1:55
COMP_ROUND_END_S :: 5.0
COMP_HALFTIME_S :: 10.0

// -comp-fast: every phase short enough that a full match fits an E2E run.
COMP_FAST_WARMUP_S :: 4.0
COMP_FAST_FREEZE_S :: 1.5
COMP_FAST_ROUND_S :: 10.0
COMP_FAST_ROUND_END_S :: 1.0
COMP_FAST_HALFTIME_S :: 1.5
COMP_FAST_FUSE_S :: 6.0

Comp_State :: struct {
	round:              int, // 1-based; the wire mirror lives in match.round
	half:               int, // 0 first half, 1 second
	t_loss_streak:      int, // economy: consecutive losses, reset on a win
	ct_loss_streak:     int,
	planted_this_round: bool, // T planted: the losing-but-planted bonus reads it
	fast:               bool, // -comp-fast timings
}

comp: Comp_State

COMP_MODE := Game_Mode {
	id              = .Comp,
	name            = "competitive",
	team_size       = 5,
	countdown_s     = COMP_WARMUP_S, // the opening phase IS the warmup
	match_len_s     = 0, // unused: rounds own the clock
	post_s          = 5,
	respawn_s       = 2,
	respawn_phases  = {.Warmup},
	drop_in         = false,
	fill_on_join    = false, // warmup stays bot-free; round starts backfill
	opening_phase   = .Warmup,
	on_kill         = comp_on_kill, // kill money; round score is the phase machine's
	tick            = comp_tick,
	on_pawn_removed = comp_on_pawn_removed,
}

comp_warmup_s :: proc() -> f32 {return comp.fast ? COMP_FAST_WARMUP_S : COMP_WARMUP_S}
comp_freeze_s :: proc() -> f32 {return comp.fast ? COMP_FAST_FREEZE_S : COMP_FREEZE_S}
comp_round_s :: proc() -> f32 {return comp.fast ? COMP_FAST_ROUND_S : COMP_ROUND_S}
comp_round_end_s :: proc() -> f32 {return comp.fast ? COMP_FAST_ROUND_END_S : COMP_ROUND_END_S}
comp_halftime_s :: proc() -> f32 {return comp.fast ? COMP_FAST_HALFTIME_S : COMP_HALFTIME_S}
comp_fuse_s :: proc() -> f32 {return comp.fast ? COMP_FAST_FUSE_S : game.BOMB_FUSE}

@(private = "file")
phase_ticks :: proc(seconds: f32) -> u32 {
	return sv.tick + u32(seconds * game.TICK_RATE)
}

comp_tick :: proc() {
	if match.phase == .Idle do return

	bomb_tick()

	// Round-deciding conditions are polled, not threaded through every kill
	// path: a fall death and a bot kill end the round exactly like a traced
	// shot, one place decides. The bomb tick above may already have ended the
	// round (defuse); these checks see the phase it left behind.
	if match.phase == .Live {
		comp_check_live()
	}
	if match.phase == .Bomb {
		comp_check_bomb()
	}

	if sv.tick < match.phase_end_tick do return

	#partial switch match.phase {
	case .Warmup:
		comp_match_begin()

	case .Freeze:
		set_phase(.Live, phase_ticks(comp_round_s()))

	case .Live:
		// The clock ran out with no plant: the defenders held.
		comp_round_end(.CT, .Time_Out)

	case .Bomb:
		comp_bomb_expired()

	case .Round_End:
		comp_route_after_round()

	case .Halftime:
		comp_swap_sides()
		comp_round_start()

	case .Post:
		// A fleet server retires and lets the master spawn a fresh one; a dev
		// server without a master just resets for the next join.
		if hb.enabled {
			begin_shutdown()
		} else {
			reset_to_idle()
		}
	}
}

// Warmup is over: the real match starts from a clean slate.
@(private = "file")
comp_match_begin :: proc() {
	match.t_score = 0
	match.ct_score = 0
	comp.round = 0
	comp.half = 0
	comp.t_loss_streak = 0
	comp.ct_loss_streak = 0
	for &slot in clients {
		if slot.state != .In_Game do continue
		slot.loadout = game.default_loadout(slot.team)
	}
	comp_economy_match_begin()
	log.infof("Server: warmup over, match begins ({} human(s))", count_humans_in_game())
	comp_round_start()
}

@(private = "file")
comp_round_start :: proc() {
	comp.round += 1
	comp.planted_this_round = false
	match.round = comp.round

	fill_bots() // backfills seats left by disconnects too
	comp_reset_round_pawns()
	bomb_round_reset()

	log.infof("Server: round {} freeze -- T {} : {} CT", comp.round, match.t_score, match.ct_score)
	set_phase(.Freeze, phase_ticks(comp_freeze_s()))
}

// Elimination wins, polled during .Live. Pre-plant, a dead T side loses even
// with the bomb on the ground.
@(private = "file")
comp_check_live :: proc() {
	t_alive, ct_alive := comp_alive_counts()
	if t_alive == 0 {
		comp_round_end(.CT, .Elimination)
	} else if ct_alive == 0 {
		comp_round_end(.T, .Elimination)
	}
}

// After the plant only the defenders' death ends the round early: a dead T
// side still wins if the fuse burns down.
@(private = "file")
comp_check_bomb :: proc() {
	_, ct_alive := comp_alive_counts()
	if ct_alive == 0 {
		comp_round_end(.T, .Bomb_Exploded)
	}
}

// The fuse burned down: detonation, then the T round. Lives in bomb.odin once
// the explosion exists; the seam is here so the phase machine reads complete.
@(private = "file")
comp_bomb_expired :: proc() {
	bomb_explode()
	comp_round_end(.T, .Bomb_Exploded)
}

comp_alive_counts :: proc() -> (t, ct: int) {
	for &p in sv.gs.pawns {
		if !p.active || !p.alive do continue
		if p.team == .T do t += 1
		else do ct += 1
	}
	return
}

// One round decided. Score it, pay it out, show it.
comp_round_end :: proc(winner: game.Team, reason: game.Round_End_Reason) {
	if winner == .T {
		match.t_score += 1
	} else {
		match.ct_score += 1
	}
	comp_economy_round_end(winner, reason)
	log.infof(
		"Server: round {} to {} ({}) -- T {} : {} CT",
		comp.round,
		winner,
		reason,
		match.t_score,
		match.ct_score,
	)
	set_phase(.Round_End, phase_ticks(comp_round_end_s()), u8(winner), reason)
}

@(private = "file")
comp_route_after_round :: proc() {
	t, ct := match.t_score, match.ct_score
	if t >= game.COMP_WIN_ROUNDS || ct >= game.COMP_WIN_ROUNDS ||
	   (t == game.COMP_HALF_ROUNDS && ct == game.COMP_HALF_ROUNDS) {
		comp_match_over()
		return
	}
	if comp.round == game.COMP_HALF_ROUNDS && comp.half == 0 {
		log.info("Server: halftime")
		set_phase(.Halftime, phase_ticks(comp_halftime_s()))
		return
	}
	comp_round_start()
}

@(private = "file")
comp_match_over :: proc() {
	winner := game.NO_WINNER
	if match.t_score > match.ct_score do winner = u8(game.Team.T)
	if match.ct_score > match.t_score do winner = u8(game.Team.CT)
	log.infof("Server: match over -- T {} : {} CT", match.t_score, match.ct_score)
	set_phase(.Post, phase_ticks(match.mode.post_s), winner, .Match_Over)
}

// Sides swap, and so does everything that belongs to a side: score, loss
// streaks, loadouts, money. The scores follow the players, so each label
// keeps showing what its current occupants earned.
@(private = "file")
comp_swap_sides :: proc() {
	for &slot in clients {
		if slot.state != .In_Game do continue
		slot.team = slot.team == .T ? .CT : .T
		slot.loadout = game.default_loadout(slot.team)
	}
	for &p, i in sv.gs.pawns {
		if p.active && p.is_bot {
			sv.gs.pawns[i] = {}
			brains[i] = {}
		}
	}
	match.t_score, match.ct_score = match.ct_score, match.t_score
	comp.t_loss_streak, comp.ct_loss_streak = comp.ct_loss_streak, comp.t_loss_streak
	comp.half = 1
	comp_economy_match_begin()
	log.infof("Server: sides swapped -- T {} : {} CT", match.t_score, match.ct_score)
}

// Round-start placement: humans first onto the inner spawn spots, bots onto
// the rest. Survivors keep gun, magazine and armor exactly as the round left
// them (deliberately NOT init_pawn + apply_loadout, both of which refill);
// the dead come back on their slot's loadout.
@(private = "file")
comp_reset_round_pawns :: proc() {
	spawn_index: [game.Team]int

	for &slot in clients {
		if slot.state != .In_Game do continue
		p := &sv.gs.pawns[slot.pawn_id]
		position := team_spawn_position_n(slot.team, spawn_index[slot.team])
		spawn_index[slot.team] += 1

		if p.active && p.alive {
			comp_reset_survivor(p, slot.team, position)
		} else {
			// The dead lost their bought guns with their life (CS rule): back
			// to the team default before the freeze buys land on top.
			slot.loadout = game.default_loadout(slot.team)
			game.init_pawn(p, position, team_spawn_yaw(slot.team))
			p.team = slot.team
			p.god = slot.debug_god
			p.infinite_ammo = slot.debug_infinite
			apply_loadout_to_pawn(p, slot.loadout)
		}
	}

	for &p, i in sv.gs.pawns {
		if !p.active || !p.is_bot do continue
		position := team_spawn_position_n(p.team, spawn_index[p.team])
		spawn_index[p.team] += 1
		if p.alive {
			comp_reset_survivor(&p, p.team, position)
		} else {
			spawn_bot_at(i, p.team, position, team_spawn_yaw(p.team))
		}
	}
	comp_bot_gear()
}

// Bots buy nothing, but from round 3 they stop being free kills: a vest that
// actually absorbs (the one real effect) and a rifle in the hands so models
// and kill feed read right. The hitscan stub underneath stays.
@(private = "file")
comp_bot_gear :: proc() {
	if comp.round < 3 do return
	for &p in sv.gs.pawns {
		if !p.active || !p.is_bot do continue
		p.armor = game.PAWN_MAX_ARMOR
		p.weapon.index = p.team == .T ? game.WEAPON_AK : game.WEAPON_M4
	}
}

@(private = "file")
comp_reset_survivor :: proc(p: ^game.Pawn, team: game.Team, position: [3]f32) {
	p.health = game.PAWN_MAX_HEALTH
	p.team = team
	p.body.position = position
	p.prev_position = position
	p.body.velocity = {}
	p.yaw = team_spawn_yaw(team)
	p.pitch = 0
	p.crouching = false
	p.respawn_in = 0
}

// A player left mid-round: the bomb must not vanish with them. Fleshed out in
// bomb.odin; the hook is wired here so drop_client never learns bomb rules.
comp_on_pawn_removed :: proc(pawn_id: int) {
	bomb_pawn_removed(pawn_id)
}
