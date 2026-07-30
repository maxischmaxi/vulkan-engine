package main

import "../game"
import "core:log"

// The competitive economy's server half: money on the client slot, awards at
// round end, kill money through the mode's on_kill hook. The numbers and the
// pure rules live in game/economy.odin; buying itself is validated in
// loadout.odin against the balance kept here.

award :: proc(slot: ^Client_Slot, amount: int) {
	slot.money = clamp(slot.money + amount, 0, game.ECON_MAX_MONEY)
}

find_slot_by_pawn :: proc(pawn_id: int) -> ^Client_Slot {
	for &slot in clients {
		if slot.state == .In_Game && slot.pawn_id == pawn_id do return &slot
	}
	return nil
}

// Warmup ended or sides swapped: everyone back to start money.
comp_economy_match_begin :: proc() {
	for &slot in clients {
		if slot.state != .In_Game do continue
		slot.money = game.ECON_START_MONEY
	}
}

// A round was decided: the winners collect, the losers climb their ladder,
// a lost-but-planted round still pays the T side. The defuser's own bonus is
// paid where the defuse is decided (server/bomb.odin).
comp_economy_round_end :: proc(winner: game.Team, reason: game.Round_End_Reason) {
	_ = reason
	if winner == .T {
		comp.t_loss_streak = 0
		comp.ct_loss_streak += 1
	} else {
		comp.ct_loss_streak = 0
		comp.t_loss_streak += 1
	}

	for &slot in clients {
		if slot.state != .In_Game do continue
		if slot.team == winner {
			award(&slot, game.ECON_WIN_REWARD)
		} else {
			streak := slot.team == .T ? comp.t_loss_streak : comp.ct_loss_streak
			award(&slot, game.loss_bonus(streak))
			if slot.team == .T && comp.planted_this_round {
				award(&slot, game.ECON_PLANT_TEAM)
			}
		}
	}
	log_round_money()
}

// Kill money, comp's on_kill hook. Bots have no wallet, team kills pay
// nothing, warmup kills are noise.
comp_on_kill :: proc(killer, victim: int) {
	if killer < 0 do return
	if match.phase == .Warmup do return
	if sv.gs.pawns[killer].team == sv.gs.pawns[victim].team do return
	slot := find_slot_by_pawn(killer)
	if slot == nil do return
	award(slot, game.kill_reward(sv.gs.pawns[killer].weapon.index))
}

@(private = "file")
log_round_money :: proc() {
	for &slot in clients {
		if slot.state != .In_Game do continue
		log.infof(
			"Server: client {} money ${} ({})",
			client_index(&slot),
			slot.money,
			slot.team,
		)
	}
}
