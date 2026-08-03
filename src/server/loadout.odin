package main

import "../game"
import "../protocol"
import "core:log"

// The server half of buying: the wire handler and what a stored loadout does
// to a pawn.

// Dresses a pawn in the slot's choice: ownership, ammo, the spawn weapon, and
// armor -- which is opt-in here, overriding the free vest init_pawn hands out.
apply_loadout_to_pawn :: proc(p: ^game.Pawn, l: game.Loadout) {
	p.loadout = l
	game.refill_pawn_ammo(&p.weapon)
	p.weapon.index = game.loadout_spawn_index(l)
	p.armor = l.armor ? game.PAWN_MAX_ARMOR : 0
	game.apply_grenades_to_pawn(p, l)
}

// The wire handler. Validation repairs rather than rejects; the choice is
// stored on the slot for the next spawn or, during a buy phase, applied to
// the live pawn immediately.
//
// TDM: everything free. Countdown applies now, Live stores for the respawn.
// Comp: only during warmup (free) and freeze (charged against the slot's
// money). Too expensive keeps the old loadout -- no wire nack, because the
// client's mirror of buy_cost already predicted the refusal.
handle_loadout :: proc(slot: ^Client_Slot, m: protocol.Loadout_Msg) {
	if slot.state != .In_Game do return

	requested := game.Loadout {
		primary    = m.primary,
		secondary  = m.secondary,
		armor      = m.armor,
		helmet     = m.helmet,
		defuse_kit = m.defuse_kit,
	}
	for kind in game.Grenade_Kind {
		requested.grenades[kind] = m.grenades[int(kind)]
	}
	l := game.validate_loadout(requested, slot.team)
	before := slot.loadout

	if match.mode.id == .Comp {
		if !game.phase_can_buy(match.phase) {
			log.infof("Server: client {} buy outside buy time, ignored", client_index(slot))
			return
		}
		if match.phase != .Warmup {
			cost := game.buy_cost(before, l)
			if cost > slot.money {
				log.infof(
					"Server: client {} insufficient funds (${} for ${})",
					client_index(slot),
					slot.money,
					cost,
				)
				return
			}
			slot.money -= cost
		}
	}

	slot.loadout = l

	p := &sv.gs.pawns[slot.pawn_id]
	apply_now := game.phase_can_buy(match.phase) && p.active && p.alive
	if apply_now {
		held := p.weapon.index
		apply_loadout_to_pawn(p, l)
		p.weapon.index = game.loadout_held_after_buy(before, l, held)
	}
	log.infof(
		"Server: client {} loadout primary={} secondary={} armor={} helmet={} kit={} nades={} ({})",
		client_index(slot),
		loadout_weapon_name(l.primary),
		loadout_weapon_name(l.secondary),
		l.armor,
		l.helmet,
		l.defuse_kit,
		l.grenades,
		apply_now ? "applied now" : "next spawn",
	)
}

@(private = "file")
loadout_weapon_name :: proc(index: i8) -> string {
	if index < 0 || int(index) >= game.WEAPON_COUNT do return "none"
	return game.WEAPONS[index].name
}
