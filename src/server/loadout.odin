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
}

// The wire handler. Validation repairs rather than rejects; the choice is
// stored on the slot for the next spawn. Only during the countdown does it go
// straight into the live pawn's hands -- waiting for a round that has not
// begun would be waiting for nothing. Mid-round, death delivers it.
//
// phase   pawn   action
// Countdown alive  store + apply immediately, bought weapon into the hand
// Live      any    store; (re)spawn applies it
// Post/Idle any    store only; a rematch resets to defaults on join anyway
handle_loadout :: proc(slot: ^Client_Slot, m: protocol.Loadout_Msg) {
	if slot.state != .In_Game do return

	l := game.validate_loadout({m.primary, m.secondary, m.armor}, slot.team)
	before := slot.loadout
	slot.loadout = l

	p := &sv.gs.pawns[slot.pawn_id]
	apply_now := match.phase == .Countdown && p.active && p.alive
	if apply_now {
		held := p.weapon.index
		apply_loadout_to_pawn(p, l)
		p.weapon.index = game.loadout_held_after_buy(before, l, held)
	}
	log.infof(
		"Server: client {} loadout primary={} secondary={} armor={} ({})",
		client_index(slot),
		loadout_weapon_name(l.primary),
		loadout_weapon_name(l.secondary),
		l.armor,
		apply_now ? "applied now" : "next spawn",
	)
}

@(private = "file")
loadout_weapon_name :: proc(index: i8) -> string {
	if index < 0 || int(index) >= game.WEAPON_COUNT do return "none"
	return game.WEAPONS[index].name
}
