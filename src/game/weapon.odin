package game

import "../physics"

// Weapons are data, not code. Adding one means adding an entry to WEAPONS --
// geometry, fire rate and handling all come from the same table, and nothing
// downstream branches on which weapon is held.
//
// The table carries the view fields too (model name, offsets): the server simply
// never reads them, and one table beats two halves that can drift.

// The mesh the client draws for this weapon, arms included. The name is what
// `just models` writes into models/, and the client looks it up there -- the
// server carries the string and never touches it.
Weapon_Model :: string

Weapon :: struct {
	name:          string,
	model:         Weapon_Model,
	// Which number key draws it. Sparse on purpose: the HUD lists every slot,
	// including the ones nothing occupies yet.
	slot:          int,
	damage:        int,
	// Rounds in a full magazine and the most that can be carried behind it.
	// A melee weapon leaves both at zero and skips ammo entirely.
	mag_size:      int,
	reserve_max:   int,
	reload_time:   f32,
	melee:         bool,
	muzzle:        [3]f32, // where the flash sits, view space
	fire_interval: f32, // seconds between shots
	automatic:     bool,
	range:         f32,
	// The models come out of scenes built around a camera at the origin, so the
	// artist's own composition is the default and this only corrects it.
	//
	// View space, metres: x right, y forward, z up, origin at the eye. There is
	// deliberately no scale beside it: scaling a model whose origin is the eye
	// moves every one of its points along the same ray, which is a change no
	// perspective projection can show.
	view_offset:   [3]f32,
	recoil_kick:   f32, // metres the weapon jumps back
}

// A fixed array rather than a slice, so len(WEAPONS) is a constant and the ammo
// table below can be sized from it.
WEAPONS := [?]Weapon {
	{
		name          = "rifle",
		model         = "view_rifle",
		slot          = 0,
		// Three hits kill a bot at full health, which is what makes the damage
		// number visible in play rather than only in the table.
		damage        = 34,
		mag_size      = 30,
		reserve_max   = 90,
		reload_time   = 2.4,
		// The front edge of the barrel, read off the model's own bounds -- the
		// converter prints them per object for exactly this.
		muzzle        = {0.08, 0.75, -0.06},
		fire_interval = 0.092, // about 650 rounds per minute
		automatic     = true,
		range         = 200,
		view_offset   = {0, 0, 0},
		recoil_kick   = 0.035,
	},
	{
		name          = "pistol",
		model         = "view_pistol",
		slot          = 1,
		damage        = 26,
		mag_size      = 12,
		reserve_max   = 60,
		reload_time   = 1.9,
		muzzle        = {0.075, 0.50, -0.12},
		fire_interval = 0.15,
		automatic     = false,
		range         = 120,
		view_offset   = {0, 0, 0},
		recoil_kick   = 0.028,
	},
	{
		name          = "knife",
		model         = "view_knife",
		slot          = 2,
		damage        = 55,
		melee         = true,
		fire_interval = 0.4,
		automatic     = false,
		// Arm's length. Long enough to reach a bot you are standing on top of
		// and nothing beyond it.
		range         = 1.4,
		view_offset   = {0, 0, 0},
		recoil_kick   = 0.06, // the swing, not a recoil
	},
}

WEAPON_COUNT :: len(WEAPONS)

// The highest number key the HUD offers. Slots past the last weapon are drawn
// empty rather than hidden, so the loadout has visible room to grow.
WEAPON_SLOTS :: 5

// Long enough that an empty magazine reads as a failure to fire rather than as
// the game dropping the click.
DRY_FIRE_COOLDOWN :: 0.3

// Brief settle after switching, so it is not a free shot.
SWITCH_COOLDOWN :: 0.25

// Rounds held per weapon, not per hand: switching away and back has to find the
// magazine as it was left.
Weapon_Ammo :: struct {
	mag:     int,
	reserve: int,
}

// The weapon occupying a slot, or -1. Slots are sparse, so callers ask rather
// than indexing.
weapon_in_slot :: proc(slot: int) -> int {
	for weapon, i in WEAPONS {
		if weapon.slot == slot do return i
	}
	return -1
}

// ------------------------------------------------- per-pawn, tick-based core
//
// The server's fire control: runs on the fixed tick, eats Pawn_Input buttons,
// traces against tick positions. The client's own frame-time firing stays
// client-side -- it is cosmetic feedback; this is the truth.

Pawn_Weapon :: struct {
	index:            int,
	cooldown:         f32, // seconds until the next shot is allowed
	reload_left:      f32, // seconds until the magazine is topped up
	trigger_was_held: bool, // semi-automatics need the release between shots
	ammo:             [WEAPON_COUNT]Weapon_Ammo,
}

Shot_Result :: struct {
	hit:    bool,
	point:  [3]f32,
	normal: [3]f32,
	pawn:   int, // -1 when the world was hit
}

Fire_Events :: struct {
	fired:  bool,
	dry:    bool,
	shot:   Shot_Result,
	killed: bool,
}

refill_pawn_ammo :: proc(w: ^Pawn_Weapon) {
	for weapon, i in WEAPONS {
		w.ammo[i] = {
			mag     = weapon.mag_size,
			reserve = weapon.reserve_max,
		}
	}
	w.reload_left = 0
}

select_pawn_weapon :: proc(w: ^Pawn_Weapon, index: int) {
	if index < 0 || index >= WEAPON_COUNT do return
	if index == w.index do return

	w.index = index
	w.cooldown = SWITCH_COOLDOWN
	// Rounds already chambered stay chambered, but the reload itself is lost --
	// swapping out mid-magazine to skip the wait is not a trade worth allowing.
	w.reload_left = 0
}

start_pawn_reload :: proc(w: ^Pawn_Weapon) -> bool {
	weapon := WEAPONS[w.index]
	ammo := w.ammo[w.index]

	if weapon.melee do return false
	if w.reload_left > 0 do return false
	if ammo.mag >= weapon.mag_size || ammo.reserve <= 0 do return false

	w.reload_left = weapon.reload_time
	return true
}

@(private = "file")
finish_pawn_reload :: proc(w: ^Pawn_Weapon) {
	weapon := WEAPONS[w.index]
	ammo := &w.ammo[w.index]

	take := min(weapon.mag_size - ammo.mag, ammo.reserve)
	ammo.mag += take
	ammo.reserve -= take
}

// The ray starts at the eye and runs along the view direction, not from the
// muzzle. That is what makes the crosshair tell the truth: a shot leaving the
// barrel would be offset from where the player is looking and would miss at
// close range.
trace_shot :: proc(gs: ^Game_State, shooter: int, origin, dir: [3]f32, range: f32) -> Shot_Result {
	result := Shot_Result {
		pawn = -1,
	}

	best_t := range
	found := false

	if hit, ok := physics.grid_raycast(&gs.grid, origin, dir, best_t); ok {
		best_t = hit.t
		result.point = hit.point
		result.normal = hit.normal
		found = true
	}

	// Pawns are tested after the world but against the tightened range, so one
	// standing in front of a wall wins and one behind it does not.
	for &p, i in gs.pawns {
		if !p.active || !p.alive || i == shooter do continue

		hit, ok := physics.ray_aabb(origin, dir, pawn_hit_box(p), best_t)
		if !ok do continue

		best_t = hit.t
		result.point = hit.point
		result.normal = hit.normal
		result.pawn = i
		found = true
	}

	result.hit = found
	return result
}

// One tick of fire control for one pawn: cooldowns, reload, switching, the
// trigger, the trace, the damage. Mirrors the client's frame-time version --
// the pair must agree on the rules even though only this one deals damage on
// a server.
tick_pawn_weapon :: proc(
	gs: ^Game_State,
	id: int,
	input: Pawn_Input,
	dt: f32,
) -> (
	ev: Fire_Events,
) {
	p := &gs.pawns[id]
	w := &p.weapon

	w.cooldown = max(w.cooldown - dt, 0)

	if w.reload_left > 0 {
		w.reload_left -= dt
		if w.reload_left <= 0 {
			w.reload_left = 0
			finish_pawn_reload(w)
		}
	}

	if input.weapon_slot >= 0 {
		if index := weapon_in_slot(int(input.weapon_slot)); index >= 0 {
			select_pawn_weapon(w, index)
		}
	}

	// A corpse holds neither trigger nor magazine.
	if !p.alive {
		w.trigger_was_held = false
		return
	}

	if .Reload in input.buttons do start_pawn_reload(w)

	pressed := .Fire in input.buttons
	clicked := .Fire_Pressed in input.buttons
	weapon := WEAPONS[w.index]

	// A semi-automatic weapon needs the trigger released between shots; an
	// automatic one only needs it held. The edge bit covers the press that
	// began and ended inside one frame, which held bits alone never see.
	wants_to_fire :=
		weapon.automatic ? (pressed || clicked) : (clicked || (pressed && !w.trigger_was_held))
	w.trigger_was_held = pressed

	if !wants_to_fire || w.cooldown > 0 do return

	// Reloading occupies the weapon, so a trigger pull during it does nothing
	// rather than cancelling the reload -- the alternative is losing a magazine
	// to a reflex click.
	if w.reload_left > 0 do return

	if !weapon.melee && w.ammo[w.index].mag <= 0 {
		// Empty stays empty. Reloading is the player's decision and costs the
		// weapon's reload time, so taking it away from them would also decide
		// when they are defenceless.
		w.cooldown = DRY_FIRE_COOLDOWN
		ev.dry = true
		return
	}

	if !weapon.melee && !p.infinite_ammo {
		w.ammo[w.index].mag -= 1
	}
	w.cooldown = weapon.fire_interval
	ev.fired = true

	ev.shot = trace_shot(gs, id, eye_position(p^), view_forward(p.yaw, p.pitch), weapon.range)
	if ev.shot.hit && ev.shot.pawn >= 0 {
		ev.killed = damage_pawn(&gs.pawns[ev.shot.pawn], weapon.damage)
		if ev.killed do p.kills += 1
	}
	return
}
