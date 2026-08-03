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

// The gap after a throw before the next wind-up may start. A held button can
// no longer run the belt dry on its own -- the throw happens on the release --
// but a fast double-click still has to cost something.
THROW_COOLDOWN :: f32(0.6)

// What the loadout gives a fresh spawn.
apply_grenades_to_pawn :: proc(p: ^Pawn, l: Loadout) {
	p.grenades = l.grenades
	p.held_grenade = -1
	p.holding_bomb = false
	p.throw_cooldown = 0
	p.wind_up = {}
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

// Whether this command is holding the throw, and which shape it asks for.
// The arm drawing back. Its own type because BOTH ends of the wire run it: the
// server off the commands it receives, the client off the commands it sends,
// and the client's trajectory preview is only honest while the two agree tick
// for tick. Sharing the procedure is the only way to be sure they do.
//
// The two buttons are tracked apart rather than as one "something is held",
// because the press EDGE of each is what the shape switch reads.
Wind_Up :: struct {
	charge:    u8, // ticks held, 0 = nothing drawn back
	underhand: bool,
	fire_held: bool,
	zoom_held: bool,
}

wind_up_winding :: proc(w: Wind_Up) -> bool {
	return w.fire_held || w.zoom_held
}

// Drops a wind-up without throwing anything. Whatever ended it -- a hand
// change, a death, the last of that kind going somewhere else -- the grenade
// stays on the belt. Counter-strike commits you the moment the pin is out;
// this is an arm being drawn back, and a misclick has no business costing the
// only flash of the round.
//
// The held flags deliberately survive: the physical buttons are still down, and
// a cancelled wind-up must not re-arm itself under the same press.
wind_up_cancel :: proc(w: ^Wind_Up) {
	w.charge = 0
	w.underhand = false
}

// One tick of the wind-up. Returns a throw on the tick the last button comes up
// with something drawn back.
tick_wind_up :: proc(
	w: ^Wind_Up,
	buttons: Buttons,
	cooldown: f32,
) -> (
	charge: f32,
	style: Throw_Style,
	throwing: bool,
) {
	fire := .Fire in buttons
	zoom := .Zoom in buttons
	fire_pressed := fire && !w.fire_held
	zoom_pressed := zoom && !w.zoom_held
	was_winding := wind_up_winding(w^)

	w.fire_held = fire
	w.zoom_held = zoom

	if fire || zoom {
		if w.charge == 0 {
			// A wind-up starts on the press edge and only with the cooldown
			// clear. Both halves matter: without the edge a button held down
			// through the cooldown rearms itself the tick it expires, which is
			// the old held-trigger behaviour wearing a new name; and a press
			// refused by the cooldown stays refused until the buttons go back
			// up, rather than quietly catching later in the same hold.
			if was_winding || cooldown > 0 do return
			// The right button alone asks for the short arc. Both at once is
			// the long one, which only matters to somebody who mashed them
			// together -- from here on the shape is switched, not chosen.
			w.underhand = zoom_pressed && !fire_pressed
			w.charge = 1
			return
		}

		// Already drawing back: a fresh press of EITHER button flips between
		// the two shapes. Not "the last button pressed wins", which sounds
		// equivalent and is not: the button already being held cannot be
		// pressed again without letting go of it, and letting go throws. A
		// toggle is the only rule that can be worked in both directions
		// without ever putting the grenade in the air by accident.
		if fire_pressed || zoom_pressed do w.underhand = !w.underhand

		w.charge = min(w.charge + 1, THROW_CHARGE_TICKS)
		return
	}

	// Released. Nothing drawn back, nothing to let go of.
	if w.charge == 0 do return

	charge = throw_charge_fraction(w.charge)
	style = w.underhand ? .Underhand : .Overhand
	throwing = true
	wind_up_cancel(w)
	return
}

// What the wind-up would throw if it were released right now. The client's
// preview is drawn from this, so it has to answer for a wind-up that has not
// happened yet -- charge 0 when nothing is drawn back.
wind_up_throw :: proc(w: Wind_Up) -> (charge: f32, style: Throw_Style) {
	return throw_charge_fraction(w.charge), w.underhand ? .Underhand : .Overhand
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
	style:    Throw_Style,
	charge:   f32, // 0..1, what the wind-up bought
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
		p.wind_up = {}
		return
	}

	// Losing the bomb empties the hand that held it, whatever the client last
	// asked for -- a plant, a death, a drop.
	if !has_bomb do p.holding_bomb = false

	before := p.held_grenade
	pawn_select(p, input.weapon_slot, has_bomb)
	// Winding up with one grenade and releasing with another would throw a kind
	// the arm never drew back.
	if p.held_grenade != before do wind_up_cancel(&p.wind_up)

	if p.held_grenade < 0 {
		wind_up_cancel(&p.wind_up)
		return
	}

	// Ran out of the kind in hand (thrown, or a fresh life): cycle to whatever
	// is left rather than holding a phantom.
	kind := Grenade_Kind(p.held_grenade)
	if p.grenades[kind] == 0 {
		p.held_grenade = next_carried_grenade(p^, p.held_grenade)
		wind_up_cancel(&p.wind_up)
		if p.held_grenade < 0 do return
		kind = Grenade_Kind(p.held_grenade)
	}

	charge, style, throwing := tick_wind_up(&p.wind_up, input.buttons, p.throw_cooldown)
	if !throwing do return

	req = Throw_Request {
		throwing = true,
		kind     = kind,
		style    = style,
		charge   = charge,
	}

	p.grenades[kind] -= 1
	p.throw_cooldown = THROW_COOLDOWN
	// Out of that kind: hands move to the next one, or back to the weapon.
	if p.grenades[kind] == 0 {
		p.held_grenade = next_carried_grenade(p^, p.held_grenade)
	}

	return
}
