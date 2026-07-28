package game

// What a player chose to carry: the buy menu's output and the spawn's input.
// The knife is always owned and never part of the choice. Everything here is
// pure and shared, so the server's application and the client's mirror cannot
// disagree.

Loadout :: struct {
	primary:   i8, // WEAPONS index, -1 for none
	secondary: i8, // WEAPONS index, always valid after validation
	armor:     bool,
}

// T spawns holding the glock, CT the usp -- counter-strike's starting pistols.
team_pistol :: proc(team: Team) -> i8 {
	return team == .T ? WEAPON_GLOCK : WEAPON_USP
}

default_loadout :: proc(team: Team) -> Loadout {
	return {primary = -1, secondary = team_pistol(team), armor = false}
}

// The weapon a number key means for this loadout: slot 0 primary, 1 secondary,
// 2 knife; -1 for an empty or unknown slot.
loadout_weapon_in_slot :: proc(l: Loadout, slot: int) -> int {
	switch slot {
	case 0:
		return int(l.primary)
	case 1:
		return int(l.secondary)
	case 2:
		return WEAPON_KNIFE
	}
	return -1
}

loadout_owns :: proc(l: Loadout, index: int) -> bool {
	return index == WEAPON_KNIFE || index == int(l.primary) || index == int(l.secondary)
}

// What a fresh spawn holds: the primary when there is one, the pistol otherwise.
loadout_spawn_index :: proc(l: Loadout) -> int {
	if l.primary >= 0 do return int(l.primary)
	return int(l.secondary)
}

// Whether this team may buy this weapon at all. The knife is owned, not bought.
weapon_allowed :: proc(index: int, team: Team) -> bool {
	if index <= WEAPON_KNIFE || index >= WEAPON_COUNT do return false
	return team in WEAPONS[index].teams
}

// Zero-trust repair: a field that is out of range, in the wrong slot or not for
// this team falls back to the team default. The message is never rejected
// wholesale -- a hand-crafted packet only ever de-buys its sender.
validate_loadout :: proc(l: Loadout, team: Team) -> Loadout {
	out := default_loadout(team)
	if weapon_allowed(int(l.primary), team) && WEAPONS[l.primary].slot == 0 {
		out.primary = l.primary
	}
	if weapon_allowed(int(l.secondary), team) && WEAPONS[l.secondary].slot == 1 {
		out.secondary = l.secondary
	}
	out.armor = l.armor
	return out
}

// The hand after a buy applied to a live pawn: the changed slot goes into the
// hand (counter-strike behaviour); an unchanged loadout keeps what was held as
// long as it is still owned. Pure, so client and server agree without an
// acknowledgement round-trip.
loadout_held_after_buy :: proc(before, after: Loadout, held: int) -> int {
	if after.primary != before.primary && after.primary >= 0 do return int(after.primary)
	if after.secondary != before.secondary do return int(after.secondary)
	if loadout_owns(after, held) do return held
	return loadout_spawn_index(after)
}
