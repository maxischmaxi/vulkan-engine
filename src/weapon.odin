package main

import "core:log"
import "core:math"
import "physics"
import "vendor:glfw"

// Weapons are data, not code. Adding one means adding an entry to WEAPONS --
// geometry, fire rate and handling all come from the same table, and nothing
// downstream branches on which weapon is held.

// A block of the weapon, in weapon space: x right, y forward (down the barrel),
// z up, origin at the grip. Metres.
Weapon_Part :: struct {
	offset: [3]f32,
	size:   [3]f32,
	color:  [3]f32,
	rough:  f32,
	metal:  f32,
}

Weapon :: struct {
	name:          string,
	parts:         []Weapon_Part,
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
	muzzle:        [3]f32, // where the flash sits, weapon space
	fire_interval: f32, // seconds between shots
	automatic:     bool,
	range:         f32,
	view_offset:   [3]f32, // grip position relative to the eye
	// Scales the whole viewmodel. Weapons are not drawn at true size in any
	// shooter: at arm's length a rifle covers most of the screen, and the part
	// nearest the eye covers the most of all. Shrinking beats moving it further
	// away, which would make it read as floating in front of the player.
	view_scale:    f32,
	// Degrees the weapon is turned inward, muzzle toward the screen centre. A
	// weapon pointing exactly along the view axis is seen end-on and foreshortens
	// into an upright block -- the shape reads only once some of its side shows.
	view_yaw:      f32,
	recoil_kick:   f32, // metres the weapon jumps back
}

// Colours are picked to read as materials at a glance: dark polymer, gunmetal,
// wood, skin.
POLYMER :: [3]f32{0.10, 0.10, 0.11}
GUNMETAL :: [3]f32{0.22, 0.23, 0.26}
WOOD :: [3]f32{0.32, 0.20, 0.10}
SKIN :: [3]f32{0.78, 0.58, 0.44}
SLEEVE :: [3]f32{0.20, 0.26, 0.20}

RIFLE_PARTS := []Weapon_Part {
	// receiver
	{offset = {0, 0.10, 0.02}, size = {0.055, 0.34, 0.09}, color = POLYMER, rough = 0.55},
	// barrel
	{
		offset = {0, 0.42, 0.035},
		size = {0.028, 0.42, 0.028},
		color = GUNMETAL,
		rough = 0.35,
		metal = 0.9,
	},
	// handguard over the barrel
	{offset = {0, 0.34, 0.035}, size = {0.048, 0.22, 0.05}, color = POLYMER, rough = 0.6},
	// magazine, angled forward by sitting slightly ahead of the grip
	{offset = {0, 0.10, -0.10}, size = {0.035, 0.10, 0.16}, color = POLYMER, rough = 0.5},
	// pistol grip
	{offset = {0, -0.03, -0.09}, size = {0.04, 0.06, 0.13}, color = POLYMER, rough = 0.65},
	// stock
	{offset = {0, -0.20, 0.01}, size = {0.045, 0.22, 0.075}, color = POLYMER, rough = 0.6},
	// iron sight block
	{
		offset = {0, 0.24, 0.085},
		size = {0.014, 0.03, 0.03},
		color = GUNMETAL,
		rough = 0.4,
		metal = 0.8,
	},
	// firing hand
	{offset = {0.005, -0.03, -0.16}, size = {0.075, 0.11, 0.10}, color = SKIN, rough = 0.8},
	{offset = {0.005, -0.10, -0.20}, size = {0.085, 0.16, 0.09}, color = SLEEVE, rough = 0.85},
	// support hand on the handguard
	{offset = {-0.005, 0.34, -0.045}, size = {0.085, 0.11, 0.10}, color = SKIN, rough = 0.8},
	{offset = {-0.02, 0.30, -0.13}, size = {0.09, 0.10, 0.13}, color = SLEEVE, rough = 0.85},
}

PISTOL_PARTS := []Weapon_Part {
	// slide
	{
		offset = {0, 0.09, 0.03},
		size = {0.04, 0.21, 0.05},
		color = GUNMETAL,
		rough = 0.35,
		metal = 0.85,
	},
	// frame under it
	{offset = {0, 0.06, -0.01}, size = {0.036, 0.15, 0.035}, color = POLYMER, rough = 0.6},
	// grip
	{offset = {0, -0.02, -0.09}, size = {0.038, 0.055, 0.13}, color = POLYMER, rough = 0.7},
	// front sight
	{
		offset = {0, 0.18, 0.06},
		size = {0.008, 0.012, 0.014},
		color = GUNMETAL,
		rough = 0.4,
		metal = 0.8,
	},
	// firing hand
	{offset = {0.005, -0.02, -0.15}, size = {0.075, 0.10, 0.10}, color = SKIN, rough = 0.8},
	{offset = {0.005, -0.08, -0.20}, size = {0.085, 0.15, 0.09}, color = SLEEVE, rough = 0.85},
	// support hand wrapped around the firing hand
	{offset = {-0.055, -0.01, -0.15}, size = {0.05, 0.10, 0.10}, color = SKIN, rough = 0.8},
	{offset = {-0.07, -0.07, -0.19}, size = {0.07, 0.14, 0.09}, color = SLEEVE, rough = 0.85},
}

KNIFE_PARTS := []Weapon_Part {
	// blade
	{
		offset = {0, 0.17, 0.015},
		size = {0.010, 0.20, 0.036},
		color = GUNMETAL,
		rough = 0.22,
		metal = 0.95,
	},
	// tip, narrower so the blade reads as pointed rather than as a bar
	{
		offset = {0, 0.29, 0.008},
		size = {0.009, 0.06, 0.022},
		color = GUNMETAL,
		rough = 0.22,
		metal = 0.95,
	},
	// guard
	{
		offset = {0, 0.06, 0},
		size = {0.048, 0.016, 0.03},
		color = GUNMETAL,
		rough = 0.4,
		metal = 0.8,
	},
	// handle
	{offset = {0, -0.02, -0.015}, size = {0.028, 0.12, 0.034}, color = POLYMER, rough = 0.7},
	// hand
	{offset = {0.005, -0.03, -0.10}, size = {0.075, 0.11, 0.10}, color = SKIN, rough = 0.8},
	{offset = {0.005, -0.10, -0.15}, size = {0.085, 0.16, 0.09}, color = SLEEVE, rough = 0.85},
}

// A fixed array rather than a slice, so len(WEAPONS) is a constant and the ammo
// table below can be sized from it.
WEAPONS := [?]Weapon {
	{
		name          = "rifle",
		parts         = RIFLE_PARTS,
		slot          = 0,
		// Three hits kill a bot at full health, which is what makes the damage
		// number visible in play rather than only in the table.
		damage        = 34,
		mag_size      = 30,
		reserve_max   = 90,
		reload_time   = 2.4,
		muzzle        = {0, 0.64, 0.035},
		fire_interval = 0.092, // about 650 rounds per minute
		automatic     = true,
		range         = 200,
		// The grip sits far enough forward that the stock, which extends 0.31 m
		// behind it, stays clear of the eye.
		view_offset   = {0.13, 0.60, -0.17},
		view_scale    = 0.8,
		view_yaw      = 7,
		recoil_kick   = 0.035,
	},
	{
		name          = "pistol",
		parts         = PISTOL_PARTS,
		slot          = 1,
		damage        = 26,
		mag_size      = 12,
		reserve_max   = 60,
		reload_time   = 1.9,
		muzzle        = {0, 0.20, 0.03},
		fire_interval = 0.15,
		automatic     = false,
		range         = 120,
		// higher and closer to centre than the rifle: a pistol is held up in
		// front of the face, and at the rifle's offset its grip and hands fall
		// off the bottom of the screen entirely
		view_offset   = {0.095, 0.46, -0.12},
		view_scale    = 0.85,
		// more than the rifle: a pistol is short, so it foreshortens harder
		view_yaw      = 13,
		recoil_kick   = 0.028,
	},
	{
		name          = "knife",
		parts         = KNIFE_PARTS,
		slot          = 2,
		damage        = 55,
		melee         = true,
		fire_interval = 0.4,
		automatic     = false,
		// Arm's length. Long enough to reach a bot you are standing on top of
		// and nothing beyond it.
		range         = 1.4,
		view_offset   = {0.11, 0.40, -0.13},
		view_scale    = 0.95,
		// turned further inward than either gun: a knife is held across the body
		view_yaw      = 20,
		recoil_kick   = 0.06, // the swing, not a recoil
	},
}

WEAPON_COUNT :: len(WEAPONS)

// The highest number key the HUD offers. Slots past the last weapon are drawn
// empty rather than hidden, so the loadout has visible room to grow.
WEAPON_SLOTS :: 5

// Rounds held per weapon, not per hand: switching away and back has to find the
// magazine as it was left.
Weapon_Ammo :: struct {
	mag:     int,
	reserve: int,
}

weapon_ammo: [WEAPON_COUNT]Weapon_Ammo

Weapon_State :: struct {
	index:        int,
	cooldown:     f32, // seconds until the next shot is allowed
	recoil:       f32, // 0..1, decays
	flash:        f32, // seconds of muzzle flash left
	trigger_held: bool,
	hit_marker:   f32, // seconds of hit feedback left
	hit_killed:   bool, // the last hit was fatal, which the marker colours differently
	reload_left:  f32, // seconds until the magazine is topped up
	shots:        int,
	hits:         int,
}

weapon_state: Weapon_State

MUZZLE_FLASH_TIME :: 0.045
HIT_MARKER_TIME :: 0.18
RECOIL_RECOVERY :: 9.0

// Long enough that an empty magazine reads as a failure to fire rather than as
// the game dropping the click.
DRY_FIRE_COOLDOWN :: 0.3

// Number keys, in slot order.
SLOT_KEYS := [WEAPON_SLOTS]i32{glfw.KEY_1, glfw.KEY_2, glfw.KEY_3, glfw.KEY_4, glfw.KEY_5}

current_weapon :: proc() -> Weapon {
	return WEAPONS[weapon_state.index]
}

current_ammo :: proc() -> Weapon_Ammo {
	return weapon_ammo[weapon_state.index]
}

// The weapon occupying a slot, or -1. Slots are sparse, so the HUD asks rather
// than indexing.
weapon_in_slot :: proc(slot: int) -> int {
	for weapon, i in WEAPONS {
		if weapon.slot == slot do return i
	}
	return -1
}

refill_all_ammo :: proc() {
	for weapon, i in WEAPONS {
		weapon_ammo[i] = {
			mag     = weapon.mag_size,
			reserve = weapon.reserve_max,
		}
	}
	weapon_state.reload_left = 0
}

init_weapons :: proc() {
	weapon_state = {}
	refill_all_ammo()
	log.infof("Weapons: {} ({} selected)", WEAPON_COUNT, current_weapon().name)
}

select_weapon :: proc(index: int) {
	if index < 0 || index >= WEAPON_COUNT do return
	if index == weapon_state.index do return

	weapon_state.index = index
	weapon_state.cooldown = 0.25 // brief settle so switching is not a free shot
	weapon_state.recoil = 0
	// Rounds already chambered stay chambered, but the reload itself is lost --
	// swapping out mid-magazine to skip the wait is not a trade worth allowing.
	weapon_state.reload_left = 0
	log.infof("Weapon: {}", current_weapon().name)
}

// ------------------------------------------------------------------ reloading

// 0 when nothing is loading, otherwise 0..1 through the animation.
reload_progress :: proc() -> f32 {
	if weapon_state.reload_left <= 0 do return 0
	weapon := current_weapon()
	if weapon.reload_time <= 0 do return 0
	return 1 - weapon_state.reload_left / weapon.reload_time
}

start_reload :: proc() -> bool {
	weapon := current_weapon()
	ammo := weapon_ammo[weapon_state.index]

	if weapon.melee do return false
	if weapon_state.reload_left > 0 do return false
	if ammo.mag >= weapon.mag_size || ammo.reserve <= 0 do return false

	weapon_state.reload_left = weapon.reload_time
	return true
}

@(private = "file")
finish_reload :: proc() {
	weapon := current_weapon()
	ammo := &weapon_ammo[weapon_state.index]

	take := min(weapon.mag_size - ammo.mag, ammo.reserve)
	ammo.mag += take
	ammo.reserve -= take
}

// -------------------------------------------------------------------- firing

// Fire control runs on real time rather than the fixed tick, and shots are
// tested against the interpolated world -- what is on screen is what gets hit.
// A server would call this lag compensation; locally it is simply the truth.
update_weapon :: proc(dt: f32, alpha: f32) {
	weapon_state.cooldown = max(weapon_state.cooldown - dt, 0)
	weapon_state.flash = max(weapon_state.flash - dt, 0)
	weapon_state.hit_marker = max(weapon_state.hit_marker - dt, 0)
	weapon_state.recoil = max(weapon_state.recoil - dt * RECOIL_RECOVERY, 0)

	if weapon_state.reload_left > 0 {
		weapon_state.reload_left -= dt
		if weapon_state.reload_left <= 0 {
			weapon_state.reload_left = 0
			finish_reload()
		}
	}

	for key, slot in SLOT_KEYS {
		if !key_pressed(key) do continue
		if index := weapon_in_slot(slot); index >= 0 do select_weapon(index)
	}

	// A corpse holds neither trigger nor magazine. The benchmark holds one
	// without a cursor to grab.
	if !player.alive || (!input.cursor_grabbed && !bench_active()) {
		weapon_state.trigger_held = false
		consume_fire_click()
		return
	}

	if key_pressed(glfw.KEY_R) do start_reload()

	pressed :=
		glfw.GetMouseButton(g.window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS || bench_fire_held()
	clicked := consume_fire_click()
	weapon := current_weapon()

	// A semi-automatic weapon needs the trigger released between shots; an
	// automatic one only needs it held. The latched click covers the press that
	// began and ended inside one frame, which polling alone never sees.
	wants_to_fire :=
		weapon.automatic ? (pressed || clicked) : (clicked || (pressed && !weapon_state.trigger_held))
	weapon_state.trigger_held = pressed

	if !wants_to_fire || weapon_state.cooldown > 0 do return

	// Reloading occupies the weapon, so a trigger pull during it does nothing
	// rather than cancelling the reload -- the alternative is losing a magazine
	// to a reflex click.
	if weapon_state.reload_left > 0 do return

	if !weapon.melee && weapon_ammo[weapon_state.index].mag <= 0 {
		// Empty stays empty. Reloading is the player's decision and costs the
		// weapon's reload time, so taking it away from them would also decide
		// when they are defenceless.
		weapon_state.cooldown = DRY_FIRE_COOLDOWN
		return
	}

	fire(alpha)
	weapon_state.cooldown = weapon.fire_interval
}

Shot_Result :: struct {
	hit:       bool,
	point:     [3]f32,
	normal:    [3]f32,
	bot_index: int, // -1 when the world was hit
}

// The ray starts at the eye and runs along the view direction, not from the
// muzzle. That is what makes the crosshair tell the truth: a shot leaving the
// barrel would be offset from where the player is looking and would miss at
// close range.
trace_shot :: proc(alpha: f32) -> Shot_Result {
	weapon := current_weapon()
	origin := player_eye()
	direction := camera_forward()

	result := Shot_Result {
		bot_index = -1,
	}

	best_t := weapon.range
	found := false

	if hit, ok := physics.ray_scene(origin, direction, world_collision, best_t); ok {
		best_t = hit.t
		result.point = hit.point
		result.normal = hit.normal
		found = true
	}

	// Bots are tested after the world but against the tightened range, so one
	// standing in front of a wall wins and one behind it does not.
	for bot, i in bots {
		if !bot.alive do continue

		hit, ok := physics.ray_aabb(origin, direction, bot_hit_box(bot, alpha), best_t)
		if !ok do continue

		best_t = hit.t
		result.point = hit.point
		result.normal = hit.normal
		result.bot_index = i
		found = true
	}

	result.hit = found
	return result
}

@(private = "file")
fire :: proc(alpha: f32) {
	weapon := current_weapon()

	if !weapon.melee && !debug.infinite_ammo {
		weapon_ammo[weapon_state.index].mag -= 1
	}

	weapon_state.shots += 1
	weapon_state.recoil = 1

	if !weapon.melee {
		weapon_state.flash = MUZZLE_FLASH_TIME

		// The flash lights the surroundings for a moment. It is a real light, so
		// walls near the muzzle brighten the way they should.
		add_transient_light(muzzle_world_position(), {1.0, 0.82, 0.5}, 26, 7, MUZZLE_FLASH_TIME)
	}

	shot := trace_shot(alpha)
	if !shot.hit do return

	if shot.bot_index >= 0 {
		weapon_state.hits += 1
		weapon_state.hit_marker = HIT_MARKER_TIME
		weapon_state.hit_killed = damage_bot(&bots[shot.bot_index], weapon.damage)
		return
	}

	// Decals only go on the world, and only from something that leaves a hole.
	if weapon.melee do return

	seed := f32(weapon_state.shots) * 0.6180339887
	add_decal(shot.point, shot.normal, seed - math.floor(seed))
}

hit_marker_alpha :: proc() -> f32 {
	if weapon_state.hit_marker <= 0 do return 0
	return weapon_state.hit_marker / HIT_MARKER_TIME
}

// ----------------------------------------------------------------- viewmodel

// Weapon space to world space. The weapon hangs off the camera basis, offset
// down and to the right the way a held rifle sits, and kicks back when fired.
@(private = "file")
weapon_origin :: proc() -> (origin, right, forward, up: [3]f32) {
	weapon := current_weapon()
	cam_right, cam_forward, cam_up := camera_basis()

	offset := weapon.view_offset
	// recoil pushes the weapon back along its own barrel and tips it up
	kick := weapon_state.recoil * weapon.recoil_kick

	origin =
		camera.position +
		cam_right * offset.x +
		cam_forward * (offset.y - kick) +
		cam_up * (offset.z + kick * 0.4)

	// The weapon's own axes, turned inward about the camera's up vector.
	angle := math.to_radians(weapon.view_yaw)
	c := math.cos(angle)
	s := math.sin(angle)

	forward = cam_forward * c - cam_right * s
	right = cam_right * c + cam_forward * s
	up = cam_up
	return
}

muzzle_world_position :: proc() -> [3]f32 {
	weapon := current_weapon()
	origin, right, forward, up := weapon_origin()
	m := weapon.muzzle * weapon.view_scale
	return origin + right * m.x + forward * m.y + up * m.z
}

// Hands every block of the weapon to the prop renderer.
submit_viewmodel :: proc() {
	weapon := current_weapon()
	origin, right, forward, up := weapon_origin()
	scale := weapon.view_scale

	for part in weapon.parts {
		offset := part.offset * scale
		center := origin + right * offset.x + forward * offset.y + up * offset.z

		add_view_prop(
			prop_transform_oriented(center, part.size * scale, right, forward, up),
			part.color,
			roughness = part.rough,
			metallic = part.metal,
		)
	}

	// The flash is a block that lights up rather than a sprite, which keeps it
	// in the same renderer as everything else.
	if weapon_state.flash > 0 {
		strength := weapon_state.flash / MUZZLE_FLASH_TIME
		muzzle := muzzle_world_position()
		size := [3]f32{0.09, 0.13, 0.09} * scale * (0.6 + 0.4 * strength)

		add_view_prop(
			prop_transform_oriented(muzzle, size, right, forward, up),
			{1.0, 0.86, 0.55},
			roughness = 1.0,
			emissive = 14 * strength,
		)
	}
}
