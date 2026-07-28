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

// The buy menu's page a weapon appears on. None means not buyable -- the knife
// is always owned.
Buy_Category :: enum u8 {
	None,
	Pistol,
	Heavy,
	SMG,
	Rifle,
}

Team_Mask :: bit_set[Team;u8]

Weapon :: struct {
	name:          string,
	model:         Weapon_Model,
	// Which number key draws it: 0 primary, 1 secondary, 2 knife.
	slot:          int,
	category:      Buy_Category,
	teams:         Team_Mask, // who may buy it; set explicitly on every entry
	price:         int, // display only -- everything is free, like casual deathmatch
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
	pellets:       int, // rays per trigger pull; 0 reads as 1
	spread:        f32, // tangent of the pellet cone half-angle; 0 = a laser
	zoom_fov:      f32, // horizontal degrees while scoped; 0 = no scope
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

// Indices into WEAPONS, by name. The knife sits at 0 so a zeroed weapon index
// is always something every pawn owns.
WEAPON_KNIFE :: 0
WEAPON_GLOCK :: 1
WEAPON_USP :: 2
WEAPON_DEAGLE :: 3
WEAPON_MAC10 :: 4
WEAPON_MP9 :: 5
WEAPON_NOVA :: 6
WEAPON_AK :: 7
WEAPON_M4 :: 8
WEAPON_AWP :: 9

// A fixed array rather than a slice, so len(WEAPONS) is a constant and the ammo
// table below can be sized from it. Order must match the constants above.
// Stats approximate counter-strike's; prices are the classic ones and purely
// cosmetic. muzzle values are read off the converter's per-object bounds.
WEAPONS := [?]Weapon {
	{
		name          = "knife",
		model         = "view_knife",
		slot          = 2,
		category      = .None,
		teams         = {.T, .CT},
		price         = 0,
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
	{
		name          = "glock",
		model         = "view_glock",
		slot          = 1,
		category      = .Pistol,
		teams         = {.T},
		price         = 0, // the starting pistol
		damage        = 28,
		mag_size      = 20,
		reserve_max   = 120,
		reload_time   = 2.2,
		muzzle        = {0.075, 0.47, -0.12},
		fire_interval = 0.15,
		automatic     = false,
		range         = 120,
		view_offset   = {0, 0, 0},
		recoil_kick   = 0.028,
	},
	{
		name          = "usp",
		model         = "view_usp",
		slot          = 1,
		category      = .Pistol,
		teams         = {.CT},
		price         = 0, // the starting pistol
		damage        = 33,
		mag_size      = 12,
		reserve_max   = 24,
		reload_time   = 2.2,
		muzzle        = {0.075, 0.51, -0.13},
		fire_interval = 0.17,
		automatic     = false,
		range         = 120,
		view_offset   = {0, 0, 0},
		recoil_kick   = 0.030,
	},
	{
		name = "deagle",
		model = "view_deagle",
		slot = 1,
		category = .Pistol,
		teams = {.T, .CT},
		price = 700,
		damage = 58,
		mag_size = 7,
		reserve_max = 35,
		reload_time = 2.2,
		muzzle = {0.075, 0.55, -0.14},
		fire_interval = 0.22,
		automatic = false,
		range = 150,
		view_offset = {0, 0, 0},
		recoil_kick = 0.050,
	},
	{
		name = "mac10",
		model = "view_mac10",
		slot = 0,
		category = .SMG,
		teams = {.T},
		price = 1050,
		damage = 26,
		mag_size = 30,
		reserve_max = 100,
		reload_time = 2.6,
		muzzle = {0.09, 0.54, -0.13},
		fire_interval = 0.075,
		automatic = true,
		range = 100,
		view_offset = {0, 0, 0},
		recoil_kick = 0.030,
	},
	{
		name = "mp9",
		model = "view_mp9",
		slot = 0,
		category = .SMG,
		teams = {.CT},
		price = 1250,
		damage = 24,
		mag_size = 30,
		reserve_max = 120,
		reload_time = 2.1,
		muzzle = {0.09, 0.56, -0.13},
		fire_interval = 0.07,
		automatic = true,
		range = 100,
		view_offset = {0.04, -0.02, -0.03},
		recoil_kick = 0.030,
	},
	{
		name          = "nova",
		model         = "view_nova",
		slot          = 0,
		category      = .Heavy,
		teams         = {.T, .CT},
		price         = 1050,
		// Per pellet. Nine fixed pellets (pellets.odin): 234 nominal at point
		// blank, about four pellets for an unarmored kill. The short range
		// still stands in for falloff.
		damage        = 26,
		mag_size      = 8,
		reserve_max   = 32,
		reload_time   = 2.9,
		muzzle        = {0.09, 0.97, -0.15},
		fire_interval = 0.9,
		automatic     = false,
		range         = 40,
		pellets       = NOVA_PELLETS,
		spread        = 0.0675, // tan of ~3.9 degrees, counter-strike's cone
		view_offset   = {0, 0, 0},
		recoil_kick   = 0.060,
	},
	{
		name          = "ak",
		model         = "view_ak",
		slot          = 0,
		category      = .Rifle,
		teams         = {.T},
		price         = 2700,
		damage        = 36,
		mag_size      = 30,
		reserve_max   = 90,
		reload_time   = 2.4,
		muzzle        = {0.09, 0.99, -0.15},
		fire_interval = 0.1, // 600 rounds per minute
		automatic     = true,
		range         = 200,
		view_offset   = {0.04, -0.03, -0.05},
		recoil_kick   = 0.040,
	},
	{
		name          = "m4",
		model         = "view_m4",
		slot          = 0,
		category      = .Rifle,
		teams         = {.CT},
		price         = 3100,
		damage        = 33,
		mag_size      = 30,
		reserve_max   = 90,
		reload_time   = 3.1,
		muzzle        = {0.09, 0.75, -0.15},
		fire_interval = 0.09, // 666 rounds per minute
		automatic     = true,
		range         = 200,
		view_offset   = {0.04, -0.03, -0.05},
		recoil_kick   = 0.035,
	},
	{
		name          = "awp",
		model         = "view_awp",
		slot          = 0,
		category      = .Rifle,
		teams         = {.T, .CT},
		price         = 4750,
		// 200 through ARMOR_ABSORB 0.5 against a full vest: 100 absorbed, 100
		// taken -- the one-shot body kill an awp is for.
		damage        = 200,
		mag_size      = 5,
		reserve_max   = 30,
		reload_time   = 3.7,
		muzzle        = {0.09, 1.04, -0.15},
		fire_interval = 1.5, // the bolt cycle
		automatic     = false,
		range         = 250,
		zoom_fov      = 30,
		view_offset   = {0.04, -0.02, -0.05},
		recoil_kick   = 0.080,
	},
}

WEAPON_COUNT :: len(WEAPONS)

// The number keys: 1 primary, 2 secondary, 3 knife.
WEAPON_SLOTS :: 3

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

// One pawn a blast connected with: the summed table damage of the pellets
// that hit (pre-armor, the damage cue's intensity) and whether one of them
// was the killing blow.
Pellet_Victim :: struct {
	pawn:    int,
	nominal: int,
	killed:  bool,
}

Fire_Events :: struct {
	// Per trigger pull, regardless of pellet count.
	fired:        bool,
	dry:          bool,
	// Every ray the pull traced -- one for most weapons, the pellet pattern
	// for a shotgun -- plus the victims aggregated across them.
	shots:        [MAX_PELLETS]Shot_Result,
	shot_count:   int,
	victims:      [MAX_PELLETS]Pellet_Victim,
	victim_count: int,
	// Why a trigger pull was refused, when one was made anyway. None on a tick
	// that never asked to fire -- see tick_pawn_weapon.
	blocked:      Fire_Block,
}

// The victim entry for a pawn, appended on first contact. Bounded by the
// pellet count, so the linear scan is the whole cost.
@(private = "file")
find_victim :: proc(ev: ^Fire_Events, pawn: int) -> ^Pellet_Victim {
	for &v in ev.victims[:ev.victim_count] {
		if v.pawn == pawn do return &v
	}
	ev.victims[ev.victim_count] = {
		pawn = pawn,
	}
	ev.victim_count += 1
	return &ev.victims[ev.victim_count - 1]
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
//
// The phase has no default on purpose: every caller has to say which match it
// is firing in, so a new one cannot silently inherit permission to shoot.
tick_pawn_weapon :: proc(
	gs: ^Game_State,
	id: int,
	input: Pawn_Input,
	dt: f32,
	phase: Match_Phase,
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
		// Which weapon a slot key means depends on what this pawn carries.
		if index := loadout_weapon_in_slot(p.loadout, int(input.weapon_slot)); index >= 0 {
			select_pawn_weapon(w, index)
		}
	}

	// Refuse the trigger before anything below reads it. Firing is the only
	// thing the phase gates: the holster above and the timers keep running, so
	// a countdown does not hand the match a frozen weapon when it ends.
	if block := pawn_fire_block(phase, p); block != .None {
		// Dropped rather than kept, to mirror the client's gate exactly: a
		// trigger held through a countdown leaves no residue on either end,
		// so the first live tick reads the same on both.
		w.trigger_was_held = false
		// Only a pull that was actually asked for is a refusal worth
		// reporting; a quiet tick is not one.
		if .Fire in input.buttons || .Fire_Pressed in input.buttons {
			ev.blocked = block
		}
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

	// One magazine round per pull, however many pellets fly. A pellet that
	// kills makes the corpse transparent to the rest of the blast (trace_shot
	// skips the dead) -- deterministically on both ends of the wire.
	origin := eye_position(p^)
	count := max(weapon.pellets, 1)
	for i in 0 ..< count {
		dir := pellet_dir(p.yaw, p.pitch, i, weapon.spread)
		shot := trace_shot(gs, id, origin, dir, weapon.range)
		ev.shots[ev.shot_count] = shot
		ev.shot_count += 1
		if !shot.hit || shot.pawn < 0 do continue

		v := find_victim(&ev, shot.pawn)
		v.nominal += weapon.damage
		if damage_pawn(&gs.pawns[shot.pawn], weapon.damage) {
			v.killed = true
			p.kills += 1
		}
	}
	return
}
