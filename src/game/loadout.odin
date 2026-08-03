package game

// What a player chose to carry: the buy menu's output and the spawn's input.
// The knife is always owned and never part of the choice. Everything here is
// pure and shared, so the server's application and the client's mirror cannot
// disagree.

Loadout :: struct {
	primary:    i8, // WEAPONS index, -1 for none
	secondary:  i8, // WEAPONS index, always valid after validation
	armor:      bool,
	// The vest's head coverage, sold separately and never on its own -- see
	// hit_group_bypasses_armor for what wearing it actually changes.
	helmet:     bool,
	// Halves the defuse; CT-only, and the one loadout field the bomb reads.
	defuse_kit: bool,
	// How many of each grenade is carried. Counts rather than flags, because
	// the flash is worth carrying two of; the per-kind cap and the total are
	// both enforced by validate_loadout.
	grenades:   [Grenade_Kind]u8,
}

// T spawns holding the glock, CT the usp -- counter-strike's starting pistols.
team_pistol :: proc(team: Team) -> i8 {
	return team == .T ? WEAPON_GLOCK : WEAPON_USP
}

default_loadout :: proc(team: Team) -> Loadout {
	return {primary = -1, secondary = team_pistol(team)}
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
	// A helmet is head coverage for a vest, not a hat: without one it is not a
	// thing the buy menu can sell, so a packet claiming otherwise loses it.
	out.helmet = l.armor && l.helmet
	out.defuse_kit = team == .CT && l.defuse_kit
	out.grenades = validate_grenades(l.grenades, team)
	return out
}

// Grenade counts a player could actually have bought: nothing their side does
// not sell, no more of one kind than its spec allows, and no more than the belt
// holds in total.
//
// The total is filled in enum order rather than proportionally, so a packet
// claiming four of everything yields the same loadout every time -- an
// arbitrary rule, but a deterministic one, and a hand-crafted packet only ever
// costs its sender the tail of their own belt.
validate_grenades :: proc(counts: [Grenade_Kind]u8, team: Team) -> (out: [Grenade_Kind]u8) {
	total := 0
	for kind in Grenade_Kind {
		if !grenade_allowed(kind, team) do continue

		want := min(int(counts[kind]), GRENADES[kind].max_carried)
		want = min(want, GRENADE_CARRY_TOTAL - total)
		if want <= 0 do continue

		out[kind] = u8(want)
		total += want
	}
	return
}

grenade_total :: proc(l: Loadout) -> int {
	total := 0
	for count in l.grenades do total += int(count)
	return total
}

// Whether one more of this kind would still be a legal belt. The buy menu grays
// a row out with it, and it is the same question validate_grenades answers.
can_carry_grenade :: proc(l: Loadout, kind: Grenade_Kind, team: Team) -> bool {
	if !grenade_allowed(kind, team) do return false
	if int(l.grenades[kind]) >= GRENADES[kind].max_carried do return false
	return grenade_total(l) < GRENADE_CARRY_TOTAL
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
