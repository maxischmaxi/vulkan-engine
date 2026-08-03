package main

import "core:log"
import "core:math/linalg"
import "game"

// The client's own idea of what is in its hands, and the one place a key press
// or a scroll notch turns into that idea.
//
// Selection has always been a local decision here: select_weapon runs off the
// key press and the wire is merely told afterwards, because a hand that waits
// for a round trip feels broken. Grenades and the bomb join the weapon on those
// terms, with the server's answer in the private block as the correction -- see
// adopt_server_hand, and the same idle-gate reasoning as the ammo and spray
// mirrors in predict.odin.
//
// The weapon itself stays in weapon_state.index. It is not one of three
// alternatives but the thing underneath: what comes back into the hands when
// the grenade leaves them.

// How long the server's hand is ignored after a local pick. Past any honest
// round trip, so a snapshot from before the pick cannot undo it, and short
// enough that a genuine disagreement heals within a blink.
HAND_ADOPT_QUIET :: f32(0.25)

hand_view: struct {
	grenade:        i8, // game.Grenade_Kind, -1 for none
	bomb:           bool,
	since_pick:     f32,
	// The client's own copy of the arm drawing back, run over the commands it
	// sends with the very procedure the server runs over the commands it
	// receives. Not a re-implementation: two integer counters over the same
	// stream of commands agree exactly, which is what makes the trajectory
	// preview a promise rather than a guess.
	wind:           game.Wind_Up,
	// Mirrored for the same reason -- it is the gate on starting a wind-up, and
	// a client that thinks it may start one the server will refuse would draw a
	// line for a throw that never happens.
	throw_cooldown: f32,
	// The pawn's velocity at the START of the current tick, the exact twin of
	// game.Pawn.prev_position. A throw inherits 60 % of it, so the preview line
	// is drawn from it -- and reading only the end-of-tick value made the line
	// jump in 64 Hz steps while strafing, because that is how often it changes.
	// With both ends the renderer can interpolate it like it interpolates
	// everything else it draws.
	prev_velocity:  [3]f32,
}

hand_reset :: proc() {
	hand_view = {
		grenade = -1,
	}
}

// Every command the client sends, shown to the wind-up. Called from
// build_local_input, which is the one place a command is built.
//
// Gated exactly the way the server gates it (tick_pawn_grenade): the wind-up
// only runs while a grenade is in the hand, so a trigger held on a rifle never
// draws anything back. The bomb is deliberately not included -- it is placed,
// not thrown.
hand_note_command :: proc(cmd: game.Pawn_Input) {
	hand_view.throw_cooldown = max(hand_view.throw_cooldown - game.TICK_DT, 0)
	// Before the movement this command is about to drive, which is what makes
	// it the start-of-tick value.
	hand_view.prev_velocity = player.body.velocity

	if hand_view.grenade < 0 || !player.alive {
		game.wind_up_cancel(&hand_view.wind)
		return
	}

	if _, _, throwing := game.tick_wind_up(&hand_view.wind, cmd.buttons, hand_view.throw_cooldown);
	   throwing {
		hand_view.throw_cooldown = game.THROW_COOLDOWN
	}
}

// What the hand would throw if the button came up now, and how far the wind-up
// has got. Zero charge means nothing is drawn back.
hand_wind_up :: proc() -> (charge: f32, style: game.Throw_Style, winding: bool) {
	charge, style = game.wind_up_throw(hand_view.wind)
	return charge, style, hand_view.wind.charge > 0
}

// Where a throw would leave from and how fast, in RENDER space -- both
// interpolated across the tick exactly the way the camera position is.
//
// This is the whole fix for a preview that juddered while strafing, and it is
// worth spelling out, because the obvious version of this code is the broken
// one. game.throw_origin reads the pawn's simulation eye, which moves once per
// tick; the camera sits at the INTERPOLATED eye and moves every frame. Anchoring
// a line 45 cm in front of the eye to one of those while looking through the
// other swings it by up to 8 degrees, sixty-four times a second -- the line
// pivots around a point that is chasing the camera.
//
// The velocity gets the same treatment for the same reason: 60 % of it goes
// into the throw, so a value that only changes on tick boundaries steps the
// whole arc every time it does. Interpolating is not a smoothing filter and does
// not lag -- it lands on the exact value the server will use, at the moment the
// tick it belongs to arrives.
hand_throw_ray :: proc() -> (origin, velocity: [3]f32) {
	charge, style, _ := hand_wind_up()
	inherited := linalg.lerp(hand_view.prev_velocity, player.body.velocity, game.clock.alpha)

	origin = camera.position + game.view_forward(camera.yaw, camera.pitch) * game.THROW_FORWARD
	velocity = game.throw_velocity(camera.yaw, camera.pitch, style, charge, inherited)
	return
}

// The viewmodel meshes for the things that are not weapons. Same names the
// converter writes (tools/convert_models.py), and the world_* variants of the
// same models are what a thrown grenade is drawn with.
GRENADE_VIEW_MODELS := [game.Grenade_Kind]string {
	.He      = "view_he",
	.Flash   = "view_flash",
	.Smoke   = "view_smoke",
	.Molotov = "view_molotov",
}

BOMB_VIEW_MODEL :: "view_c4"

// What the hands are showing, when it is not the weapon.
hand_view_model :: proc() -> (mesh: string, held: bool) {
	if hand_view.bomb do return BOMB_VIEW_MODEL, true
	if hand_view.grenade >= 0 {
		return GRENADE_VIEW_MODELS[game.Grenade_Kind(hand_view.grenade)], true
	}
	return "", false
}

// Whether the hands are on something that is not a gun. The trigger is dead
// while they are -- the server strips it in sim_tick, and the client's own fire
// path has to agree or it draws a muzzle flash for a shot nobody fired.
hand_busy :: proc() -> bool {
	return hand_view.grenade >= 0 || hand_view.bomb
}

hand_current :: proc() -> game.Hand {
	if hand_view.bomb do return {kind = .Bomb}
	if hand_view.grenade >= 0 do return {kind = .Grenade, index = hand_view.grenade}
	return {kind = .Weapon, index = i8(current_weapon().slot)}
}

// Whether the local player is the one carrying the bomb, which is what makes it
// selectable at all. Mirrors what the server asks in bomb_carried_by.
local_carries_bomb :: proc() -> bool {
	if hud_preview_active() do return hud_preview.carry_bomb
	if local_sim_active() do return false
	return net_client.bomb_state == .Carried && net_client.bomb_carrier == net_client.pawn_id
}

// Everything the wheel can stop on, in the shared order.
hand_carry :: proc() -> (items: [game.MAX_CARRY]game.Hand, count: int) {
	return game.carry_items(player.loadout, player.grenades, local_carries_bomb())
}

// Puts an item in the hands and returns the code to send. Weapons go through
// select_weapon so the draw animation, the scope and the spray reset all happen
// the way a number key has always made them happen.
hand_pick :: proc(h: game.Hand) -> i8 {
	hand_view.since_pick = 0
	// Whatever was drawn back belongs to the item that is leaving the hand.
	game.wind_up_cancel(&hand_view.wind)

	switch h.kind {
	case .Weapon:
		hand_view.grenade = -1
		hand_view.bomb = false
		if index := game.loadout_weapon_in_slot(player.loadout, int(h.index)); index >= 0 {
			select_weapon(index)
		}
	case .Grenade:
		hand_view.grenade = h.index
		hand_view.bomb = false
		reset_zoom() // a grenade is not a scope
	case .Bomb:
		hand_view.grenade = -1
		hand_view.bomb = true
		reset_zoom()
	}
	return game.select_code(h)
}

// One notch of the wheel. Returns the code to send, or SELECT_NONE when there
// was nothing to move to.
hand_scroll :: proc(delta: int) -> i8 {
	items, count := hand_carry()
	next, ok := game.carry_cycle(items[:count], hand_current(), delta)
	if !ok do return game.SELECT_NONE
	return hand_pick(next)
}

// Which number key means the bomb, counted in SLOT_KEYS positions rather than
// in select codes -- key 5 sits right after the belt's key 4.
KEY_SLOT_BOMB :: game.GRENADE_SLOT + 1

// A number key, by its position in SLOT_KEYS. The belt walk happens here rather
// than travelling as a cycle request, so the hand moves on this frame like
// every other pick and the wire carries the item that was landed on.
hand_key :: proc(slot: int) -> i8 {
	switch {
	case slot < game.WEAPON_SLOTS:
		if game.loadout_weapon_in_slot(player.loadout, slot) < 0 do return game.SELECT_NONE
		return hand_pick({kind = .Weapon, index = i8(slot)})
	case slot == game.GRENADE_SLOT:
		next := game.next_carried_grenade(player^, hand_view.grenade)
		if next < 0 do return game.SELECT_NONE
		return hand_pick({kind = .Grenade, index = next})
	case slot == KEY_SLOT_BOMB:
		if !local_carries_bomb() do return game.SELECT_NONE
		return hand_pick({kind = .Bomb})
	}
	return game.SELECT_NONE
}

hand_tick :: proc(dt: f32) {
	hand_view.since_pick += dt
	defer if cli.hand_log do log_hand_changes()

	// Things that empty the hand without anybody asking: the belt ran out, the
	// bomb was planted or dropped, the round took the pawn away.
	if !player.alive {
		hand_view.grenade = -1
		hand_view.bomb = false
		return
	}
	if hand_view.grenade >= 0 && player.grenades[game.Grenade_Kind(hand_view.grenade)] == 0 {
		hand_view.grenade = game.next_carried_grenade(player^, hand_view.grenade)
	}
	if hand_view.bomb && !local_carries_bomb() do hand_view.bomb = false
}

// --hand-log: one line whenever the belt or the hand moves. Every step of the
// chain shows up in it -- the server's counts arriving, a pick being made, the
// hand being corrected -- and none of it needs a key press to observe.
@(private = "file")
log_hand_changes :: proc() {
	@(static) last_counts: [game.Grenade_Kind]u8
	@(static) last_hand: game.Hand
	@(static) seeded: bool

	hand := hand_current()
	if seeded && last_counts == player.grenades && last_hand == hand do return
	last_counts = player.grenades
	last_hand = hand
	seeded = true

	held := "c4"
	switch hand.kind {
	case .Weapon:
		held = current_weapon().name
	case .Grenade:
		held = game.GRENADES[game.Grenade_Kind(hand.index)].name
	case .Bomb:
	}

	log.infof(
		"HAND: {} belt he={} flash={} smoke={} molotov={} bomb={}",
		held,
		player.grenades[.He],
		player.grenades[.Flash],
		player.grenades[.Smoke],
		player.grenades[.Molotov],
		local_carries_bomb(),
	)
}

// The server's word, taken only once the local pick has had time to reach it.
//
// Deliberately narrow: the weapon in the hands is never overruled from here --
// reconcile already adopts the server's weapon index on respawn, and letting a
// snapshot from a round trip ago re-holster mid-fight would be a new way to
// lose a duel. All this can do is put a grenade or the bomb down, or pick one
// up that the client missed.
adopt_server_hand :: proc(code: i8) {
	if hand_view.since_pick < HAND_ADOPT_QUIET do return

	item, ok := game.select_item(code)
	if !ok do return
	if item == hand_current() do return

	switch item.kind {
	case .Weapon:
		hand_view.grenade = -1
		hand_view.bomb = false
	case .Grenade:
		hand_view.grenade = item.index
		hand_view.bomb = false
	case .Bomb:
		hand_view.grenade = -1
		hand_view.bomb = true
	}
}
