package game

import "core:testing"

// The zone mapping is pure arithmetic, so the tests pin the exact boundaries:
// an off-by-one in a threshold moves every headshot in the game.

@(test)
test_hit_group_standing_zones :: proc(t: ^testing.T) {
	h := f32(1.8) // PLAYER_HEIGHT
	testing.expect_value(t, hit_group_from_height(1.70, 0, h), Hit_Group.Head)
	testing.expect_value(t, hit_group_from_height(1.53, 0, h), Hit_Group.Head) // 0.85 exactly
	testing.expect_value(t, hit_group_from_height(1.20, 0, h), Hit_Group.Chest)
	testing.expect_value(t, hit_group_from_height(0.99, 0, h), Hit_Group.Chest) // 0.55 exactly
	testing.expect_value(t, hit_group_from_height(0.80, 0, h), Hit_Group.Stomach)
	testing.expect_value(t, hit_group_from_height(0.72, 0, h), Hit_Group.Stomach) // 0.40 exactly
	testing.expect_value(t, hit_group_from_height(0.50, 0, h), Hit_Group.Legs)
	testing.expect_value(t, hit_group_from_height(0.18, 0, h), Hit_Group.Legs) // 0.10 exactly
	testing.expect_value(t, hit_group_from_height(0.09, 0, h), Hit_Group.Feet)
	testing.expect_value(t, hit_group_from_height(0.00, 0, h), Hit_Group.Feet)
}

@(test)
test_hit_group_uses_feet_origin :: proc(t: ^testing.T) {
	// the same body standing on a crate: zones follow the feet, not the world
	testing.expect_value(t, hit_group_from_height(11.60, 10, 1.8), Hit_Group.Head)
	testing.expect_value(t, hit_group_from_height(10.50, 10, 1.8), Hit_Group.Legs)
}

@(test)
test_hit_group_short_hulls :: proc(t: ^testing.T) {
	// crouched player: the head rides at 0.9, not 1.8
	testing.expect_value(t, hit_group_from_height(0.80, 0, 0.9), Hit_Group.Head)
	testing.expect_value(t, hit_group_from_height(0.50, 0, 0.9), Hit_Group.Chest)
	// the bot hull
	testing.expect_value(t, hit_group_from_height(1.00, 0, 1.1), Hit_Group.Head)
	testing.expect_value(t, hit_group_from_height(0.65, 0, 1.1), Hit_Group.Chest)
	// a degenerate hull resolves to no zone rather than dividing by zero
	testing.expect_value(t, hit_group_from_height(0.5, 0, 0), Hit_Group.None)
}

@(test)
test_scaled_damage_truncates :: proc(t: ^testing.T) {
	testing.expect_value(t, scaled_damage(40, .Head), 160)
	testing.expect_value(t, scaled_damage(40, .Chest), 40)
	testing.expect_value(t, scaled_damage(40, .Stomach), 50)
	testing.expect_value(t, scaled_damage(40, .Legs), 30)
	testing.expect_value(t, scaled_damage(40, .Feet), 24)
	// truncation, not rounding: 33 * 1.25 = 41.25 -> 41, 33 * 0.75 = 24.75 -> 24
	testing.expect_value(t, scaled_damage(33, .Stomach), 41)
	testing.expect_value(t, scaled_damage(33, .Legs), 24)
	// the awp leg shot the balance hinges on: 115 * 0.75 = 86.25 -> 86, no kill
	testing.expect_value(t, scaled_damage(115, .Legs), 86)
	testing.expect_value(t, scaled_damage(115, .None), 115)
}

@(test)
test_hit_group_armor_coverage :: proc(t: ^testing.T) {
	testing.expect(t, hit_group_bypasses_armor(.Legs))
	testing.expect(t, hit_group_bypasses_armor(.Feet))
	testing.expect(t, !hit_group_bypasses_armor(.Head))
	testing.expect(t, !hit_group_bypasses_armor(.Chest))
	testing.expect(t, !hit_group_bypasses_armor(.Stomach))
	testing.expect(t, !hit_group_bypasses_armor(.None))
}
