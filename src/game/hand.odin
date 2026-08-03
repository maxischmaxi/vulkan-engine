package game

// What a pawn can have in its hands, as one ordered list.
//
// Three separate ideas used to answer "what am I holding": weapon.index for a
// gun, held_grenade for a grenade, and nothing at all for the bomb. That is
// enough while the only way to switch is a number key, because a key names its
// own answer. A scroll wheel does not -- it says "one further along", which
// only means something against a list both ends of the wire agree on.
//
// So the list lives here, pure and shared, and the wire carries the item rather
// than the direction. The client works out where a scroll lands and names it;
// the server checks the name against what the pawn actually carries.

Hand_Kind :: enum u8 {
	Weapon,
	Grenade,
	Bomb,
}

// index is a WEAPONS index for .Weapon, a Grenade_Kind for .Grenade, and
// unused for .Bomb.
Hand :: struct {
	kind:  Hand_Kind,
	index: i8,
}

// Weapon slots plus every grenade kind plus the bomb: the longest the carry
// list can get.
MAX_CARRY :: WEAPON_SLOTS + GRENADE_COUNT + 1

// ------------------------------------------------------------ the wire codes
//
// All of this rides the one byte Pawn_Input.weapon_slot already spends
// (protocol/messages.odin), so naming an exact item costs nothing.
//
//   -1        no change
//   0 .. 2    weapon slot, what number keys 1-3 have always meant
//   3         GRENADE_SLOT -- cycle the belt, what key 4 has always meant
//   4 .. 7    this exact grenade kind
//   8         the bomb
//
// Codes 0..3 keep their old meaning on purpose: a command from before the
// scroll wheel existed still means what it meant.

SELECT_NONE :: i8(-1)
SELECT_GRENADE_FIRST :: i8(INPUT_SLOTS)
SELECT_BOMB :: i8(INPUT_SLOTS + GRENADE_COUNT)
INPUT_SELECT_COUNT :: int(SELECT_BOMB) + 1

#assert(int(SELECT_GRENADE_FIRST) > GRENADE_SLOT)

select_grenade :: proc(kind: Grenade_Kind) -> i8 {
	return SELECT_GRENADE_FIRST + i8(kind)
}

// The item a code names, and whether it names one at all. A cycle request
// (GRENADE_SLOT) is not an item, so it answers false here and is handled where
// the belt is known.
select_item :: proc(code: i8) -> (h: Hand, ok: bool) {
	switch {
	case code < 0 || int(code) >= INPUT_SELECT_COUNT:
		return {}, false
	case code < WEAPON_SLOTS:
		return Hand{kind = .Weapon, index = code}, true
	case code == GRENADE_SLOT:
		return {}, false
	case code == SELECT_BOMB:
		return Hand{kind = .Bomb}, true
	}
	return Hand{kind = .Grenade, index = code - SELECT_GRENADE_FIRST}, true
}

// The code that would ask for this hand again. Weapons name their slot rather
// than their weapon index, because a slot is what the loadout resolves.
select_code :: proc(h: Hand) -> i8 {
	switch h.kind {
	case .Weapon:
		return h.index
	case .Grenade:
		return SELECT_GRENADE_FIRST + h.index
	case .Bomb:
		return SELECT_BOMB
	}
	return SELECT_NONE
}

// ------------------------------------------------------------- the carry list

// Everything this pawn can put in its hands, in counter-strike's key order:
// primary, secondary, knife, grenades in kind order, bomb last.
//
// Empty slots and grenade kinds with nothing left are simply absent, which is
// what keeps the wheel from stopping on an empty hand.
carry_items :: proc(
	l: Loadout,
	grenades: [Grenade_Kind]u8,
	has_bomb: bool,
) -> (
	items: [MAX_CARRY]Hand,
	count: int,
) {
	for slot in 0 ..< WEAPON_SLOTS {
		if loadout_weapon_in_slot(l, slot) < 0 do continue
		items[count] = {kind = .Weapon, index = i8(slot)}
		count += 1
	}
	for kind in Grenade_Kind {
		if grenades[kind] == 0 do continue
		items[count] = {kind = .Grenade, index = i8(kind)}
		count += 1
	}
	if has_bomb {
		items[count] = {kind = .Bomb}
		count += 1
	}
	return
}

// Whether this hand is one of the carried items. The server's answer to a
// client naming something it does not have.
carry_holds :: proc(items: []Hand, h: Hand) -> bool {
	for item in items {
		if item == h do return true
	}
	return false
}

// What this pawn is holding right now. The server answers it into the private
// block so the owner's client can heal a disagreement; a weapon answers with
// its slot rather than its index, because a slot is what a code names.
pawn_hand :: proc(p: Pawn) -> Hand {
	if p.holding_bomb do return {kind = .Bomb}
	if p.held_grenade >= 0 do return {kind = .Grenade, index = p.held_grenade}
	return {kind = .Weapon, index = i8(WEAPONS[p.weapon.index].slot)}
}

// Applies one selection command to the hands. Which weapon a slot means is
// resolved by the weapon path, which reads the same field; this owns the two
// hands that are not weapons, and the invariant that at most one is full.
//
// Zero trust: a code naming a grenade kind the pawn is not carrying, or the
// bomb it is not holding, is ignored rather than granted, so a hand-crafted
// packet can only ever put down what its sender already had.
pawn_select :: proc(p: ^Pawn, code: i8, has_bomb: bool) {
	if code < 0 do return

	// Key 4 still cycles the belt, for a client that does not work out where a
	// scroll lands on its own.
	if int(code) == GRENADE_SLOT {
		p.held_grenade = next_carried_grenade(p^, p.held_grenade)
		p.holding_bomb = false
		return
	}

	item, ok := select_item(code)
	if !ok do return

	switch item.kind {
	case .Weapon:
		p.held_grenade = -1
		p.holding_bomb = false
	case .Grenade:
		if p.grenades[Grenade_Kind(item.index)] == 0 do return
		p.held_grenade = item.index
		p.holding_bomb = false
	case .Bomb:
		if !has_bomb do return
		p.held_grenade = -1
		p.holding_bomb = true
	}
}

// One step of the wheel. Wraps, so scrolling never runs out of items, and a
// hand that is not in the list (the weapon was just dropped, the last flash was
// just thrown) starts the walk from the front rather than going nowhere.
carry_cycle :: proc(items: []Hand, current: Hand, delta: int) -> (next: Hand, ok: bool) {
	if len(items) == 0 do return {}, false
	if delta == 0 do return current, carry_holds(items, current)

	from := -1
	for item, i in items {
		if item == current do from = i
	}
	if from < 0 {
		// Not holding anything on the list: the first step lands on the first
		// item going forwards, the last one going backwards.
		from = delta > 0 ? -1 : 0
	}
	return items[(from + delta) %% len(items)], true
}
