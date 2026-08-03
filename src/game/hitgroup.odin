package game

// Where on a body a shot landed. Enemies are boxes today, so the zone comes
// from the hit's height alone; once per-limb hitboxes exist, the trace writes
// the group directly and the height mapping retires. The damage math below
// never cares which of the two produced the group.

Hit_Group :: enum u8 {
	None, // the world, or a hull with no height to divide
	Head,
	Chest,
	Stomach,
	Legs,
	Feet,
}

// Zone floors as fractions of the hull height, feet at 0. Fractions rather
// than metres so a crouched hull (0.9) and the short bot hull (1.1) divide the
// same way the standing 1.8 does.
HIT_HEAD_MIN :: f32(0.85)
HIT_CHEST_MIN :: f32(0.55)
HIT_STOMACH_MIN :: f32(0.40)
HIT_LEGS_MIN :: f32(0.10)

hit_group_from_height :: proc(hit_z, feet_z, height: f32) -> Hit_Group {
	if height <= 0 do return .None
	frac := (hit_z - feet_z) / height
	switch {
	case frac >= HIT_HEAD_MIN:
		return .Head
	case frac >= HIT_CHEST_MIN:
		return .Chest
	case frac >= HIT_STOMACH_MIN:
		return .Stomach
	case frac >= HIT_LEGS_MIN:
		return .Legs
	}
	return .Feet
}

// Counter-strike's multipliers, the headshot at four.
@(rodata)
HIT_GROUP_MULTIPLIER := [Hit_Group]f32 {
	.None    = 1,
	.Head    = 4,
	.Chest   = 1,
	.Stomach = 1.25,
	.Legs    = 0.75,
	.Feet    = 0.6,
}

// Truncated, not rounded: both ends of the wire must land on the same integer.
scaled_damage :: proc(base: int, group: Hit_Group) -> int {
	return int(f32(base) * HIT_GROUP_MULTIPLIER[group])
}

// Counter-strike's rule: the vest does not cover the legs, and it covers the
// head only when a helmet was bought with it. The helmet therefore does not
// scale headshot damage down -- it lets the vest see the hit at all, which is
// the same thing by a different route and needs no second multiplier table.
//
// Defaulted so every call site that has no victim to ask -- the tests, and any
// caller predating the helmet -- keeps the pre-helmet behaviour of a head the
// vest covers.
hit_group_bypasses_armor :: proc(group: Hit_Group, helmet := true) -> bool {
	if group == .Head do return !helmet
	return group == .Legs || group == .Feet
}
