package game

import "core:testing"

// validate_loadout is the server's only defence against a hand-crafted buy:
// it repairs rather than rejects, so every field it cannot honour has to fall
// back to something the player could have bought legitimately. The gear rules
// matter twice over, because buy_cost prices whatever comes out of here.

@(test)
test_validate_loadout_repairs_weapons :: proc(t: ^testing.T) {
	// a CT weapon on a T falls back to the team default
	l := validate_loadout({primary = WEAPON_M4, secondary = WEAPON_USP}, .T)
	testing.expect_value(t, l.primary, i8(-1))
	testing.expect_value(t, l.secondary, i8(WEAPON_GLOCK))

	// out of range in either direction, and the knife, are all refused
	l = validate_loadout({primary = WEAPON_COUNT, secondary = -9}, .CT)
	testing.expect_value(t, l.primary, i8(-1))
	testing.expect_value(t, l.secondary, i8(WEAPON_USP))
	l = validate_loadout({primary = WEAPON_KNIFE, secondary = WEAPON_KNIFE}, .CT)
	testing.expect_value(t, l.primary, i8(-1))
	testing.expect_value(t, l.secondary, i8(WEAPON_USP))

	// a pistol in the primary slot is in the wrong slot, not merely unusual
	l = validate_loadout({primary = WEAPON_DEAGLE, secondary = WEAPON_USP}, .CT)
	testing.expect_value(t, l.primary, i8(-1))

	// a legal buy survives untouched
	l = validate_loadout({primary = WEAPON_AWP, secondary = WEAPON_DEAGLE}, .CT)
	testing.expect_value(t, l.primary, i8(WEAPON_AWP))
	testing.expect_value(t, l.secondary, i8(WEAPON_DEAGLE))
}

@(test)
test_validate_loadout_helmet_needs_a_vest :: proc(t: ^testing.T) {
	// the helmet on its own is not purchasable, so it does not survive
	l := validate_loadout({primary = -1, secondary = WEAPON_USP, helmet = true}, .CT)
	testing.expect(t, !l.armor)
	testing.expect(t, !l.helmet)

	// with the vest under it, it stays
	l = validate_loadout({primary = -1, secondary = WEAPON_USP, armor = true, helmet = true}, .CT)
	testing.expect(t, l.armor)
	testing.expect(t, l.helmet)

	// a vest without a helmet is a perfectly ordinary buy
	l = validate_loadout({primary = -1, secondary = WEAPON_USP, armor = true}, .CT)
	testing.expect(t, l.armor)
	testing.expect(t, !l.helmet)
}

@(test)
test_validate_loadout_kit_is_ct_only :: proc(t: ^testing.T) {
	l := validate_loadout({primary = -1, secondary = WEAPON_GLOCK, defuse_kit = true}, .T)
	testing.expect(t, !l.defuse_kit, "a T cannot carry a defuse kit")

	l = validate_loadout({primary = -1, secondary = WEAPON_USP, defuse_kit = true}, .CT)
	testing.expect(t, l.defuse_kit)
}

// The two rules compose: stripping the kit must not cost the vest, and
// stripping the helmet must not cost the kit.
@(test)
test_validate_loadout_gear_rules_are_independent :: proc(t: ^testing.T) {
	full := Loadout {
		primary    = WEAPON_AK,
		secondary  = WEAPON_GLOCK,
		armor      = true,
		helmet     = true,
		defuse_kit = true,
	}
	l := validate_loadout(full, .T)
	testing.expect_value(t, l.primary, i8(WEAPON_AK))
	testing.expect(t, l.armor)
	testing.expect(t, l.helmet)
	testing.expect(t, !l.defuse_kit, "the T loses only the kit")

	helmetless := full
	helmetless.armor = false
	l = validate_loadout(helmetless, .CT)
	testing.expect(t, !l.helmet, "no vest, no helmet")
	testing.expect(t, l.defuse_kit, "the kit is unaffected by the vest")
}

// What a fresh loadout carries, and what it does not: the buy menu seeds its
// pending state from this, so armour leaking in here would be a free vest.
@(test)
test_default_loadout_carries_no_gear :: proc(t: ^testing.T) {
	for team in Team {
		l := default_loadout(team)
		testing.expect_value(t, l.primary, i8(-1))
		testing.expect_value(t, l.secondary, team_pistol(team))
		testing.expect(t, !l.armor)
		testing.expect(t, !l.helmet)
		testing.expect(t, !l.defuse_kit)
		testing.expect_value(t, buy_cost(l, l), 0)
	}
}
