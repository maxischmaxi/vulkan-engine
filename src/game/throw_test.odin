package game

import "core:testing"

// Selecting and throwing. The belt is server-authoritative, so every rule that
// stops a player throwing more than they bought lives here rather than in the
// buy menu -- the menu only has to agree with it.

@(private = "file")
armed :: proc(counts: [Grenade_Kind]u8) -> (p: Pawn) {
	init_pawn(&p, {0, 0, 0}, 0)
	p.grenades = counts
	return
}

@(private = "file")
select_grenades :: proc(p: ^Pawn) -> Throw_Request {
	return tick_pawn_grenade(p, {weapon_slot = GRENADE_SLOT, buttons = {}}, false, TICK_DT)
}

@(private = "file")
select_hand :: proc(p: ^Pawn, code: i8, has_bomb := false) -> Throw_Request {
	return tick_pawn_grenade(p, {weapon_slot = code, buttons = {}}, has_bomb, TICK_DT)
}

@(private = "file")
pull_trigger :: proc(p: ^Pawn, buttons: Buttons) -> Throw_Request {
	return tick_pawn_grenade(p, {weapon_slot = -1, buttons = buttons}, false, TICK_DT)
}

// Winds the arm up for `ticks` and lets go. The release is the throw, so the
// request comes back from the last call rather than the first.
@(private = "file")
wind_and_release :: proc(p: ^Pawn, ticks: int, buttons := Buttons{.Fire}) -> Throw_Request {
	for _ in 0 ..< ticks do pull_trigger(p, buttons)
	return pull_trigger(p, {})
}

// Idles until a fresh wind-up is allowed again.
@(private = "file")
wait_out_cooldown :: proc(p: ^Pawn) {
	// A variable, not the constant expression: int() of a constant 38.4 is a
	// compile error rather than a truncation.
	cooldown := f32(THROW_COOLDOWN)
	for _ in 0 ..< int(cooldown * TICK_RATE) + 2 do pull_trigger(p, {})
}

@(test)
test_throw_consumes_one_grenade :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 0, .Molotov = 0})

	select_grenades(&p)
	testing.expect(t, p.held_grenade >= 0, "the grenade slot must put one in hand")

	req := wind_and_release(&p, 10)
	testing.expect(t, req.throwing)
	testing.expect_value(t, req.style, Throw_Style.Overhand)
	testing.expect_value(t, pawn_grenade_total(p), 2)
}

// The release throws, not the press. Holding the button is aiming.
@(test)
test_holding_does_not_throw :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 0})
	select_grenades(&p)

	thrown := 0
	for _ in 0 ..< int(THROW_CHARGE_TICKS) * 3 {
		if pull_trigger(&p, {.Fire}).throwing do thrown += 1
	}
	testing.expect_value(t, thrown, 0)
	testing.expect_value(t, p.wind_up.charge, THROW_CHARGE_TICKS)

	testing.expect(t, pull_trigger(&p, {}).throwing, "letting go must throw")
	testing.expect_value(t, p.wind_up.charge, u8(0))
}

// Longer hold, faster throw -- up to the cap and no further.
@(test)
test_charge_buys_distance :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 0})

	select_grenades(&p)
	tap := wind_and_release(&p, 1)
	testing.expect(t, tap.throwing)

	wait_out_cooldown(&p)
	full := wind_and_release(&p, int(THROW_CHARGE_TICKS) * 2)
	testing.expect(t, full.throwing)

	testing.expect(t, tap.charge < full.charge, "a tap must not buy a full throw")
	testing.expect_value(t, full.charge, f32(1))
	testing.expect(
		t,
		throw_speed(.Overhand, tap.charge) < throw_speed(.Overhand, full.charge),
		"charge must reach the speed",
	)
	testing.expect_value(t, throw_speed(.Overhand, 1), f32(THROW_SPEED_MAX))
}

// The right button alone asks for the short arc, and no amount of winding up
// can make it a long one.
@(test)
test_right_button_is_the_underhand :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 0})

	select_grenades(&p)
	req := wind_and_release(&p, 10, {.Zoom})
	testing.expect_value(t, req.style, Throw_Style.Underhand)
	testing.expect_value(t, throw_speed(.Underhand, 1), f32(THROW_UNDERHAND_SPEED))
}

// Tapping the other button while the arm is drawn back switches between the two
// shapes, from either side. A toggle rather than "the last press wins": the
// button already being held cannot be pressed again without letting go of it,
// and letting go is what throws.
@(test)
test_tapping_switches_the_shape :: proc(t: ^testing.T) {
	tap :: proc(p: ^Pawn, hold, other: Buttons) {
		pull_trigger(p, hold + other) // the press edge
		pull_trigger(p, hold) // still winding on the first button
	}

	p := armed({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 0})
	select_grenades(&p)

	// Holding left: long, short, long again.
	for _ in 0 ..< 5 do pull_trigger(&p, {.Fire})
	testing.expect(t, !p.wind_up.underhand, "the left button starts long")
	tap(&p, {.Fire}, {.Zoom})
	testing.expect(t, p.wind_up.underhand, "one tap must reach the short arc")
	tap(&p, {.Fire}, {.Zoom})
	testing.expect(t, !p.wind_up.underhand, "a second tap must come back")

	// The wind-up survives the switching, and the release throws what is showing.
	testing.expect(t, p.wind_up.charge > 5, "switching must not drop the charge")
	tap(&p, {.Fire}, {.Zoom})
	testing.expect_value(t, pull_trigger(&p, {}).style, Throw_Style.Underhand)

	// And the same the other way round: holding right, tapping left.
	wait_out_cooldown(&p)
	for _ in 0 ..< 5 do pull_trigger(&p, {.Zoom})
	testing.expect(t, p.wind_up.underhand, "the right button starts short")
	tap(&p, {.Zoom}, {.Fire})
	testing.expect(t, !p.wind_up.underhand, "tapping left must reach the long arc")
	testing.expect_value(t, pull_trigger(&p, {}).style, Throw_Style.Overhand)
}

// Changing hands mid-wind-up drops the throw without costing the grenade.
@(test)
test_switching_cancels_the_wind_up :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 1, .Smoke = 0, .Molotov = 0})

	select_hand(&p, select_grenade(.He))
	for _ in 0 ..< 20 do pull_trigger(&p, {.Fire})
	testing.expect(t, p.wind_up.charge > 0)

	select_hand(&p, select_grenade(.Flash))
	testing.expect_value(t, p.wind_up.charge, u8(0))
	testing.expect(t, !pull_trigger(&p, {}).throwing, "a cancelled wind-up threw anyway")
	testing.expect_value(t, pawn_grenade_total(p), 2)
}

@(test)
test_cannot_throw_what_is_not_carried :: proc(t: ^testing.T) {
	p := armed({})
	select_grenades(&p)
	testing.expect_value(t, p.held_grenade, i8(-1))
	testing.expect(t, !wind_and_release(&p, 10).throwing, "an empty belt throws nothing")

	// One grenade, thrown, then nothing left.
	p = armed({.He = 1, .Flash = 0, .Smoke = 0, .Molotov = 0})
	select_grenades(&p)
	testing.expect(t, wind_and_release(&p, 10).throwing)
	wait_out_cooldown(&p)
	testing.expect(t, !wind_and_release(&p, 10).throwing, "threw a grenade it did not have")
	testing.expect_value(t, p.held_grenade, i8(-1))
}

// A button held across a throw must not fire again the instant the cooldown
// expires: that is the old held-trigger behaviour under a new name.
@(test)
test_held_button_does_not_rearm :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 0})
	select_grenades(&p)

	testing.expect(t, wind_and_release(&p, 10).throwing)

	cooldown := f32(THROW_COOLDOWN)
	thrown := 0
	for _ in 0 ..< int(cooldown * TICK_RATE) * 3 {
		if pull_trigger(&p, {.Fire}).throwing do thrown += 1
	}
	testing.expect_value(t, thrown, 0)
	testing.expect_value(t, p.wind_up.charge, u8(0))
}

// Pressing the slot again cycles, which is how counter-strike's key 4 behaves.
@(test)
test_grenade_slot_cycles :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 1, .Smoke = 1, .Molotov = 0})

	seen: [GRENADE_COUNT]bool
	for _ in 0 ..< GRENADE_COUNT * 2 {
		select_grenades(&p)
		testing.expect(t, p.held_grenade >= 0)
		seen[p.held_grenade] = true
	}
	testing.expect(t, seen[Grenade_Kind.He] && seen[Grenade_Kind.Flash] && seen[Grenade_Kind.Smoke])
	testing.expect(t, !seen[Grenade_Kind.Molotov], "cycled onto one that is not carried")

	// Any other slot puts them away.
	select_hand(&p, 0)
	testing.expect_value(t, p.held_grenade, i8(-1))
}

// The scroll wheel names an exact kind rather than asking for "the next one",
// because a wheel can turn backwards and a cycle cannot express that.
@(test)
test_exact_grenade_selection :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 1, .Smoke = 0, .Molotov = 0})

	select_hand(&p, select_grenade(.Flash))
	testing.expect_value(t, p.held_grenade, i8(Grenade_Kind.Flash))

	select_hand(&p, select_grenade(.He))
	testing.expect_value(t, p.held_grenade, i8(Grenade_Kind.He))
}

// Zero trust: naming a kind the belt does not hold leaves the hand as it was.
// A crafted packet may put something down, never pick something up.
@(test)
test_uncarried_grenade_is_refused :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 0, .Smoke = 0, .Molotov = 0})

	select_hand(&p, select_grenade(.He))
	testing.expect_value(t, p.held_grenade, i8(Grenade_Kind.He))

	select_hand(&p, select_grenade(.Smoke))
	testing.expect_value(t, p.held_grenade, i8(Grenade_Kind.He))
}

// The bomb is a hand like a grenade is: only the carrier may hold it, and it
// empties the other hand.
@(test)
test_bomb_hand_needs_the_carry :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 0, .Smoke = 0, .Molotov = 0})

	select_hand(&p, SELECT_BOMB, has_bomb = false)
	testing.expect(t, !p.holding_bomb, "held a bomb it is not carrying")

	select_hand(&p, select_grenade(.He))
	select_hand(&p, SELECT_BOMB, has_bomb = true)
	testing.expect(t, p.holding_bomb)
	testing.expect_value(t, p.held_grenade, i8(-1))

	// Planting, dying or dropping it takes it out of the hands on its own.
	tick_pawn_grenade(&p, {weapon_slot = -1}, false, TICK_DT)
	testing.expect(t, !p.holding_bomb, "kept the bomb after losing the carry")
}

@(test)
test_dead_pawns_drop_the_grenade :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 1, .Smoke = 0, .Molotov = 0})
	select_grenades(&p)
	testing.expect(t, p.held_grenade >= 0)

	// Wound up and then killed: neither the throw nor the grenade survives.
	for _ in 0 ..< 20 do pull_trigger(&p, {.Fire})
	p.alive = false
	req := pull_trigger(&p, {})
	testing.expect(t, !req.throwing, "a corpse threw a grenade")
	testing.expect_value(t, p.held_grenade, i8(-1))
	testing.expect_value(t, p.wind_up.charge, u8(0))
	testing.expect_value(t, pawn_grenade_total(p), 2)
}

// ---------------------------------------------------------------- the belt

@(test)
test_validate_grenades_caps_each_kind :: proc(t: ^testing.T) {
	// Four flashes asked for, two allowed.
	out := validate_grenades({.Flash = 4, .He = 0, .Smoke = 0, .Molotov = 0}, .T)
	testing.expect_value(t, out[Grenade_Kind.Flash], u8(GRENADES[.Flash].max_carried))

	// The he is a one-off.
	out = validate_grenades({.He = 3, .Flash = 0, .Smoke = 0, .Molotov = 0}, .T)
	testing.expect_value(t, out[Grenade_Kind.He], u8(1))
}

@(test)
test_validate_grenades_caps_the_total :: proc(t: ^testing.T) {
	// Everything at once is over the belt: 1 he + 2 flash + 1 smoke + 1 molly
	// is five, and the belt holds four.
	out := validate_grenades({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 1}, .T)

	total := 0
	for c in out do total += int(c)
	testing.expect_value(t, total, GRENADE_CARRY_TOTAL)

	// Deterministic: the same over-full request twice yields the same belt.
	again := validate_grenades({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 1}, .T)
	testing.expect_value(t, out, again)
}

@(test)
test_validate_grenades_respects_teams :: proc(t: ^testing.T) {
	out := validate_grenades({.Molotov = 1, .He = 0, .Flash = 0, .Smoke = 0}, .CT)
	testing.expect_value(t, out[Grenade_Kind.Molotov], u8(0))

	out = validate_grenades({.Molotov = 1, .He = 0, .Flash = 0, .Smoke = 0}, .T)
	testing.expect_value(t, out[Grenade_Kind.Molotov], u8(1))
}

@(test)
test_can_carry_grenade :: proc(t: ^testing.T) {
	empty := default_loadout(.T)
	testing.expect(t, can_carry_grenade(empty, .He, .T))
	testing.expect(t, can_carry_grenade(empty, .Molotov, .T))
	testing.expect(t, !can_carry_grenade(empty, .Molotov, .CT), "wrong side")

	// One he is the limit for that kind.
	one_he := empty
	one_he.grenades[Grenade_Kind.He] = 1
	testing.expect(t, !can_carry_grenade(one_he, .He, .T))
	testing.expect(t, can_carry_grenade(one_he, .Flash, .T))

	// A full belt takes nothing more, whatever the per-kind cap says.
	full := empty
	full.grenades[Grenade_Kind.He] = 1
	full.grenades[Grenade_Kind.Flash] = 2
	full.grenades[Grenade_Kind.Smoke] = 1
	testing.expect_value(t, grenade_total(full), GRENADE_CARRY_TOTAL)
	testing.expect(t, !can_carry_grenade(full, .Molotov, .T))
}

@(test)
test_grenade_prices :: proc(t: ^testing.T) {
	before := default_loadout(.T)
	after := before
	after.grenades[Grenade_Kind.Flash] = 2
	after.grenades[Grenade_Kind.He] = 1
	testing.expect_value(
		t,
		buy_cost(before, after),
		2 * GRENADES[.Flash].price + GRENADES[.He].price,
	)

	// Keeping what is already carried is free; losing one refunds nothing.
	testing.expect_value(t, buy_cost(after, after), 0)
	testing.expect_value(t, buy_cost(after, before), 0)

	// Topping up from one flash to two charges for one.
	one := before
	one.grenades[Grenade_Kind.Flash] = 1
	two := before
	two.grenades[Grenade_Kind.Flash] = 2
	testing.expect_value(t, buy_cost(one, two), GRENADES[.Flash].price)
}
