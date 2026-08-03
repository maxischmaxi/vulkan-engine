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

@(test)
test_throw_consumes_one_grenade :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 0, .Molotov = 0})

	select_grenades(&p)
	testing.expect(t, p.held_grenade >= 0, "the grenade slot must put one in hand")

	req := pull_trigger(&p, {.Fire})
	testing.expect(t, req.throwing)
	testing.expect_value(t, req.mode, Throw_Mode.Long)
	testing.expect_value(t, pawn_grenade_total(p), 2)
}

// One press, one grenade. Holding the button down must not empty the belt.
@(test)
test_held_trigger_throws_once :: proc(t: ^testing.T) {
	p := armed({.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 0})
	select_grenades(&p)

	// A variable, not the constant expression: int() of a constant 38.4 is a
	// compile error rather than a truncation.
	cooldown := f32(THROW_COOLDOWN)
	cooldown_ticks := int(cooldown * TICK_RATE)

	thrown := 0
	for _ in 0 ..< cooldown_ticks {
		if pull_trigger(&p, {.Fire}).throwing do thrown += 1
	}
	testing.expect_value(t, thrown, 1)

	// Past the cooldown a second one is allowed -- a fast double-click is a
	// player's business, not the belt's.
	for _ in 0 ..< cooldown_ticks + 2 {
		pull_trigger(&p, {})
	}
	testing.expect(t, pull_trigger(&p, {.Fire}).throwing, "cooldown never expired")
}

@(test)
test_throw_modes_off_the_mouse_buttons :: proc(t: ^testing.T) {
	long, ok1 := throw_mode_from_buttons({.Fire})
	testing.expect(t, ok1)
	testing.expect_value(t, long, Throw_Mode.Long)

	short, ok2 := throw_mode_from_buttons({.Zoom})
	testing.expect(t, ok2)
	testing.expect_value(t, short, Throw_Mode.Short)

	medium, ok3 := throw_mode_from_buttons({.Fire, .Zoom})
	testing.expect(t, ok3)
	testing.expect_value(t, medium, Throw_Mode.Medium)

	_, ok4 := throw_mode_from_buttons({.Jump, .Crouch})
	testing.expect(t, !ok4, "no mouse button is no throw")
}

@(test)
test_cannot_throw_what_is_not_carried :: proc(t: ^testing.T) {
	p := armed({})
	select_grenades(&p)
	testing.expect_value(t, p.held_grenade, i8(-1))
	testing.expect(t, !pull_trigger(&p, {.Fire}).throwing, "an empty belt throws nothing")

	// One grenade, thrown, then nothing left.
	p = armed({.He = 1, .Flash = 0, .Smoke = 0, .Molotov = 0})
	select_grenades(&p)
	testing.expect(t, pull_trigger(&p, {.Fire}).throwing)
	cooldown := f32(THROW_COOLDOWN)
	for _ in 0 ..< int(cooldown * TICK_RATE) + 2 do pull_trigger(&p, {})
	testing.expect(t, !pull_trigger(&p, {.Fire}).throwing, "threw a grenade it did not have")
	testing.expect_value(t, p.held_grenade, i8(-1))
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

	p.alive = false
	req := pull_trigger(&p, {.Fire})
	testing.expect(t, !req.throwing, "a corpse threw a grenade")
	testing.expect_value(t, p.held_grenade, i8(-1))
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
