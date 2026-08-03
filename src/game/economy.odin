package game

// The competitive economy's numbers and pure rules, shared so the client's
// buy menu grays out exactly what the server refuses. Money itself lives on
// the server's client slots; the client only ever sees its own balance via
// the snapshot's private block.

ECON_START_MONEY :: 800
ECON_MAX_MONEY :: 16000
ECON_WIN_REWARD :: 3250
ECON_PLANT_BONUS :: 300 // the planter, the moment the bomb is down
ECON_PLANT_TEAM :: 800 // every T at round end when they planted but lost
ECON_DEFUSE_BONUS :: 300 // the defuser, on the defuse win
ECON_ARMOR_PRICE :: 650
// The surcharge on top of the vest, not a standalone price: counter-strike
// sells the pair at 1000, and validate_loadout refuses a helmet without one.
ECON_HELMET_PRICE :: 350
ECON_DEFUSE_KIT_PRICE :: 400

// Consecutive losses climb this ladder; a win resets the streak (a deliberate
// simplification of CS2's decay-by-one).
ECON_LOSS_BONUS := [5]int{1400, 1900, 2400, 2900, 3400}

loss_bonus :: proc(streak: int) -> int {
	if streak <= 0 do return 0
	return ECON_LOSS_BONUS[min(streak - 1, len(ECON_LOSS_BONUS) - 1)]
}

// Reward per kill by the weapon that made it, CS-flavoured: SMGs pay more,
// the AWP pays almost nothing, the knife pays a fortune.
kill_reward :: proc(weapon_index: int) -> int {
	if weapon_index < 0 || weapon_index >= WEAPON_COUNT do return 300
	if weapon_index == WEAPON_KNIFE do return 1500
	if weapon_index == WEAPON_AWP do return 100
	#partial switch WEAPONS[weapon_index].category {
	case .SMG:
		return 600
	case .Heavy:
		return 900
	}
	return 300
}

// What moving from one loadout to another costs. Rebuying what is already in
// the slot is free, dropping a slot refunds nothing, and gear is bought once --
// so taking the vest off and putting it back on in the same freeze is free,
// exactly like re-picking the weapon already in the slot.
//
// Call this with a validated `after`: the helmet-needs-a-vest and CT-only-kit
// rules live in validate_loadout, and pricing an unvalidated loadout would
// charge for gear the server is about to strip.
buy_cost :: proc(before, after: Loadout) -> int {
	cost := 0
	if after.primary != before.primary && after.primary >= 0 {
		cost += WEAPONS[after.primary].price
	}
	if after.secondary != before.secondary {
		cost += WEAPONS[after.secondary].price
	}
	if after.armor && !before.armor {
		cost += ECON_ARMOR_PRICE
	}
	if after.helmet && !before.helmet {
		cost += ECON_HELMET_PRICE
	}
	if after.defuse_kit && !before.defuse_kit {
		cost += ECON_DEFUSE_KIT_PRICE
	}
	// Only the ones added: grenades are the first item that can be held more
	// than once, so this counts a difference rather than testing a flag.
	// Throwing one and rebuying it in the next freeze is a fresh purchase,
	// which is the counter-strike behaviour and falls out of the same rule.
	for kind in Grenade_Kind {
		added := int(after.grenades[kind]) - int(before.grenades[kind])
		if added > 0 do cost += added * GRENADES[kind].price
	}
	return cost
}
