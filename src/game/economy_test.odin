package game

import "core:testing"

// The economy's pure rules. The server charges and awards with exactly these
// procs, the client grays rows with them; a drifting number here is a player
// seeing a buy the server refuses.

@(test)
test_kill_reward_table :: proc(t: ^testing.T) {
	testing.expect_value(t, kill_reward(WEAPON_KNIFE), 1500)
	testing.expect_value(t, kill_reward(WEAPON_AWP), 100)
	testing.expect_value(t, kill_reward(WEAPON_AK), 300)
	testing.expect_value(t, kill_reward(WEAPON_M4), 300)
	testing.expect_value(t, kill_reward(WEAPON_GLOCK), 300)
	testing.expect_value(t, kill_reward(WEAPON_DEAGLE), 300)
	testing.expect_value(t, kill_reward(WEAPON_MAC10), 600)
	testing.expect_value(t, kill_reward(WEAPON_MP9), 600)
	testing.expect_value(t, kill_reward(WEAPON_NOVA), 900)
	// out of range falls back to the rifle reward, never crashes
	testing.expect_value(t, kill_reward(-1), 300)
	testing.expect_value(t, kill_reward(WEAPON_COUNT), 300)
}

@(test)
test_loss_bonus_ladder :: proc(t: ^testing.T) {
	testing.expect_value(t, loss_bonus(0), 0)
	testing.expect_value(t, loss_bonus(1), 1400)
	testing.expect_value(t, loss_bonus(2), 1900)
	testing.expect_value(t, loss_bonus(3), 2400)
	testing.expect_value(t, loss_bonus(4), 2900)
	testing.expect_value(t, loss_bonus(5), 3400)
	// the ladder clamps, however long the losing goes on
	testing.expect_value(t, loss_bonus(12), 3400)
}

@(test)
test_buy_cost :: proc(t: ^testing.T) {
	base := default_loadout(.T) // glock, no primary, no armor

	// a rifle and a vest cost sticker price
	bought := base
	bought.primary = WEAPON_AK
	bought.armor = true
	testing.expect_value(t, buy_cost(base, bought), WEAPONS[WEAPON_AK].price + ECON_ARMOR_PRICE)

	// resending the same loadout is free (the reliable channel may repeat)
	testing.expect_value(t, buy_cost(bought, bought), 0)

	// swapping the primary charges the new one, refunds nothing
	swapped := bought
	swapped.primary = WEAPON_AWP
	testing.expect_value(t, buy_cost(bought, swapped), WEAPONS[WEAPON_AWP].price)

	// dropping the primary is free
	dropped := bought
	dropped.primary = -1
	testing.expect_value(t, buy_cost(bought, dropped), 0)

	// armor is bought once; keeping it costs nothing
	testing.expect_value(t, buy_cost(bought, bought), 0)

	// upgrade pistol: the starting pistols are free, the deagle is not
	pistol := base
	pistol.secondary = WEAPON_DEAGLE
	testing.expect_value(t, buy_cost(base, pistol), WEAPONS[WEAPON_DEAGLE].price)
}

@(test)
test_buy_cost_gear :: proc(t: ^testing.T) {
	base := default_loadout(.CT)

	// the pair from nothing, counter-strike's 1000
	pair := base
	pair.armor = true
	pair.helmet = true
	testing.expect_value(t, buy_cost(base, pair), ECON_ARMOR_PRICE + ECON_HELMET_PRICE)
	testing.expect_value(t, ECON_ARMOR_PRICE + ECON_HELMET_PRICE, 1000)

	// the helmet alone, once the vest is already on: the surcharge only
	vested := base
	vested.armor = true
	testing.expect_value(t, buy_cost(vested, pair), ECON_HELMET_PRICE)

	// gear is bought once, and taking it off refunds nothing
	testing.expect_value(t, buy_cost(pair, pair), 0)
	testing.expect_value(t, buy_cost(pair, base), 0)

	// the kit prices independently of the vest
	kit := base
	kit.defuse_kit = true
	testing.expect_value(t, buy_cost(base, kit), ECON_DEFUSE_KIT_PRICE)

	// a full CT buy adds up to the sum of its parts
	full := pair
	full.defuse_kit = true
	full.primary = WEAPON_M4
	testing.expect_value(
		t,
		buy_cost(base, full),
		WEAPONS[WEAPON_M4].price + ECON_ARMOR_PRICE + ECON_HELMET_PRICE + ECON_DEFUSE_KIT_PRICE,
	)
}
