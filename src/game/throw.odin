package game

// Selecting and throwing a grenade: the rules between a button and a
// projectile leaving the hand.
//
// Kept off the fire path on purpose. tick_pawn_weapon carries the spray
// pattern, the lag-compensated trace and the anti-cheat's fire telemetry, and
// none of that has anything to say about a grenade. Instead the trigger is
// taken off the command before the weapon sees it -- the same move
// bomb_hands_busy makes on the server, for the same reason.

// The slot number that means "grenades" to the number keys. 0 primary,
// 1 secondary, 2 knife, 3 grenades.
GRENADE_SLOT :: 3

// One throw per press, plus enough of a gap that a held button does not empty
// the belt. Counter-strike makes you re-press; this is the same idea with a
// tolerance for a fast double-click.
THROW_COOLDOWN :: f32(0.6)

// What the loadout gives a fresh spawn.
apply_grenades_to_pawn :: proc(p: ^Pawn, l: Loadout) {
	p.grenades = l.grenades
	p.held_grenade = -1
	p.holding_bomb = false
	p.throw_cooldown = 0
}

pawn_has_grenade :: proc(p: Pawn, kind: Grenade_Kind) -> bool {
	return p.grenades[kind] > 0
}

pawn_grenade_total :: proc(p: Pawn) -> int {
	total := 0
	for count in p.grenades do total += int(count)
	return total
}

// The next kind still carried, starting after `from`. Wraps, and returns -1
// when the belt is empty. Pressing the grenade slot repeatedly cycles with
// this, which is how counter-strike's key 4 behaves.
next_carried_grenade :: proc(p: Pawn, from: i8) -> i8 {
	for step in 1 ..= GRENADE_COUNT {
		candidate := (int(from) + step) %% GRENADE_COUNT
		if p.grenades[Grenade_Kind(candidate)] > 0 do return i8(candidate)
	}
	// Still holding one that is still carried: keep it rather than dropping to
	// empty-handed on a second press with only one kind left.
	if from >= 0 && p.grenades[Grenade_Kind(from)] > 0 do return from
	return -1
}

// Whether this command asks to throw. Both mouse buttons are throw modes, so
// either edge counts; holding neither does nothing.
throw_mode_from_buttons :: proc(buttons: Buttons) -> (mode: Throw_Mode, wants: bool) {
	fire := .Fire in buttons
	zoom := .Zoom in buttons
	switch {
	case fire && zoom:
		return .Medium, true
	case fire:
		return .Long, true
	case zoom:
		return .Short, true
	}
	return .Long, false
}

// The one entry point for grenade handling, called once per tick per pawn
// before fire control. Returns whether the trigger has been consumed, in which
// case the caller must strip Fire and Zoom from the command -- otherwise the
// same press would also fire the weapon that comes back into the hands.
//
// The actual projectile is spawned by the caller (it needs the world), which
// is what keeps this testable without one.
Throw_Request :: struct {
	throwing: bool,
	kind:     Grenade_Kind,
	mode:     Throw_Mode,
}

tick_pawn_grenade :: proc(
	p: ^Pawn,
	input: Pawn_Input,
	has_bomb: bool,
	dt: f32,
) -> (
	req: Throw_Request,
) {
	p.throw_cooldown = max(p.throw_cooldown - dt, 0)

	if !p.alive {
		p.held_grenade = -1
		p.holding_bomb = false
		return
	}

	// Losing the bomb empties the hand that held it, whatever the client last
	// asked for -- a plant, a death, a drop.
	if !has_bomb do p.holding_bomb = false

	pawn_select(p, input.weapon_slot, has_bomb)

	if p.held_grenade < 0 do return

	// Ran out of the kind in hand (thrown, or a fresh life): cycle to whatever
	// is left rather than holding a phantom.
	kind := Grenade_Kind(p.held_grenade)
	if p.grenades[kind] == 0 {
		p.held_grenade = next_carried_grenade(p^, p.held_grenade)
		if p.held_grenade < 0 do return
		kind = Grenade_Kind(p.held_grenade)
	}

	if p.throw_cooldown > 0 do return

	mode, wants := throw_mode_from_buttons(input.buttons)
	if !wants do return

	p.grenades[kind] -= 1
	p.throw_cooldown = THROW_COOLDOWN
	// Out of that kind: hands move to the next one, or back to the weapon.
	if p.grenades[kind] == 0 {
		p.held_grenade = next_carried_grenade(p^, p.held_grenade)
	}

	return {throwing = true, kind = kind, mode = mode}
}
