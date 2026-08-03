package game

import "core:testing"

// The list the scroll wheel walks. Both ends of the wire build it from the same
// loadout and the same counts, so what matters here is that the order is fixed,
// that nothing unowned ever appears in it, and that a code survives the trip
// through the wire byte unchanged.

@(private = "file")
kitted :: proc() -> Loadout {
	return Loadout{primary = WEAPON_AK, secondary = WEAPON_GLOCK}
}

@(test)
test_carry_order_is_counter_strikes :: proc(t: ^testing.T) {
	items, count := carry_items(kitted(), {.He = 1, .Smoke = 1, .Flash = 0, .Molotov = 0}, true)

	testing.expect_value(t, count, 6)
	testing.expect_value(t, items[0], Hand{kind = .Weapon, index = 0}) // primary
	testing.expect_value(t, items[1], Hand{kind = .Weapon, index = 1}) // secondary
	testing.expect_value(t, items[2], Hand{kind = .Weapon, index = 2}) // knife
	testing.expect_value(t, items[3], Hand{kind = .Grenade, index = i8(Grenade_Kind.He)})
	testing.expect_value(t, items[4], Hand{kind = .Grenade, index = i8(Grenade_Kind.Smoke)})
	testing.expect_value(t, items[5], Hand{kind = .Bomb})
}

// Nothing you do not have. An empty primary slot and a spent grenade kind are
// both simply absent, which is what keeps the wheel off an empty hand.
@(test)
test_carry_skips_what_is_not_owned :: proc(t: ^testing.T) {
	pistol_only := Loadout {
		primary   = -1,
		secondary = WEAPON_USP,
	}
	items, count := carry_items(pistol_only, {}, false)

	testing.expect_value(t, count, 2)
	testing.expect_value(t, items[0], Hand{kind = .Weapon, index = 1})
	testing.expect_value(t, items[1], Hand{kind = .Weapon, index = 2})
}

@(test)
test_cycle_wraps_both_ways :: proc(t: ^testing.T) {
	items, count := carry_items(kitted(), {.He = 1, .Flash = 0, .Smoke = 0, .Molotov = 0}, false)
	list := items[:count] // ak, glock, knife, he

	next, ok := carry_cycle(list, {kind = .Weapon, index = 0}, 1)
	testing.expect(t, ok)
	testing.expect_value(t, next, Hand{kind = .Weapon, index = 1})

	// off the end of the list and back to the front
	next, _ = carry_cycle(list, {kind = .Grenade, index = i8(Grenade_Kind.He)}, 1)
	testing.expect_value(t, next, Hand{kind = .Weapon, index = 0})

	// and the other way round
	next, _ = carry_cycle(list, {kind = .Weapon, index = 0}, -1)
	testing.expect_value(t, next, Hand{kind = .Grenade, index = i8(Grenade_Kind.He)})
}

// Scrolling while holding something that just left the list (the last flash was
// thrown, the weapon was swapped out) has to land somewhere rather than nowhere.
@(test)
test_cycle_from_an_unheld_item :: proc(t: ^testing.T) {
	items, count := carry_items(kitted(), {}, false)
	list := items[:count]

	next, ok := carry_cycle(list, {kind = .Grenade, index = i8(Grenade_Kind.Molotov)}, 1)
	testing.expect(t, ok)
	testing.expect_value(t, next, Hand{kind = .Weapon, index = 0})

	next, _ = carry_cycle(list, {kind = .Grenade, index = i8(Grenade_Kind.Molotov)}, -1)
	testing.expect_value(t, next, Hand{kind = .Weapon, index = 2})
}

@(test)
test_empty_carry_cycles_nowhere :: proc(t: ^testing.T) {
	empty: []Hand
	_, ok := carry_cycle(empty, {kind = .Weapon, index = 0}, 1)
	testing.expect(t, !ok, "cycled a list with nothing in it")
}

// The wire byte: every item has a code, every code decodes back to its item.
@(test)
test_select_codes_round_trip :: proc(t: ^testing.T) {
	cases := [?]Hand {
		{kind = .Weapon, index = 0},
		{kind = .Weapon, index = 2},
		{kind = .Grenade, index = i8(Grenade_Kind.He)},
		{kind = .Grenade, index = i8(Grenade_Kind.Molotov)},
		{kind = .Bomb},
	}
	for want in cases {
		got, ok := select_item(select_code(want))
		testing.expect(t, ok)
		testing.expect_value(t, got, want)
	}
}

// The three meanings that predate the wheel keep them: 0-2 are weapon slots and
// 3 is the cycle, which is not an item and says so.
@(test)
test_legacy_codes_keep_their_meaning :: proc(t: ^testing.T) {
	got, ok := select_item(0)
	testing.expect(t, ok)
	testing.expect_value(t, got, Hand{kind = .Weapon, index = 0})

	_, cycles := select_item(GRENADE_SLOT)
	testing.expect(t, !cycles, "the cycle request is not an item")

	_, none := select_item(SELECT_NONE)
	testing.expect(t, !none)

	_, past := select_item(i8(INPUT_SELECT_COUNT))
	testing.expect(t, !past, "a code past the table must decode to nothing")
}
