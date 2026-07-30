package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "game"
import "physics"
import "vendor:glfw"

// The client half of the weapon: reading the mouse, the frame-time fire loop,
// recoil, flashes, hit markers, the viewmodel. The table and the tick-based
// core the server fires with live in game/weapon.odin -- this file is what a
// weapon feels like, that one is what a weapon is.

Weapon_State :: struct {
	index:        int,
	cooldown:     f32, // seconds until the next shot is allowed
	recoil:       f32, // 0..1, decays
	flash:        f32, // seconds of muzzle flash left
	trigger_held: bool,
	hit_marker:   f32, // seconds of hit feedback left
	hit_killed:   bool, // the last hit was fatal, which the marker colours differently
	reload_left:  f32, // seconds until the magazine is topped up
	draw_left:    f32, // seconds left of the swap the weapon is drawn out of
	zoom_active:  bool, // scoped in; the camera lens follows this
	shots:        int,
	hits:         int,
	// The cosmetic mirror of the server's spray burst (game/weapon.odin).
	spray:        game.Spray_Track,
}

weapon_state: Weapon_State

weapon_ammo: [game.WEAPON_COUNT]game.Weapon_Ammo

// The client's own stance-cone draws, for decals and practice damage. Online
// the server draws its own and decides damage; the two disagreeing while the
// feet move is by design. Self-seeds from entropy; the bench pins it.
cosmetic_rng_state: rand.Default_Random_State
cosmetic_rng := rand.default_random_generator(&cosmetic_rng_state)

MUZZLE_FLASH_TIME :: 0.045
HIT_MARKER_TIME :: 0.18
RECOIL_RECOVERY :: 9.0

// Number keys, in slot order: primary, secondary, knife.
SLOT_KEYS := [game.WEAPON_SLOTS]i32{glfw.KEY_1, glfw.KEY_2, glfw.KEY_3}

current_weapon :: proc() -> game.Weapon {
	return game.WEAPONS[weapon_state.index]
}

current_ammo :: proc() -> game.Weapon_Ammo {
	return weapon_ammo[weapon_state.index]
}

refill_all_ammo :: proc() {
	for weapon, i in game.WEAPONS {
		weapon_ammo[i] = {
			mag     = weapon.mag_size,
			reserve = weapon.reserve_max,
		}
	}
	weapon_state.reload_left = 0
	// Mirrors refill_pawn_ammo: a respawn into the same weapon index skips
	// select_weapon's reset, so the burst must end here too.
	game.spray_track_reset(&weapon_state.spray)
}

// The loadout a life starts with before any buying: the team default, bent by
// --weapon for screenshot runs, and a full kit in the benchmark.
seed_loadout :: proc() -> game.Loadout {
	// The cli flag rather than bench_active(): this runs from the startup init,
	// before the bench itself is up.
	team := scene.chosen_team
	loadout := game.default_loadout(team)
	if cli.bench > 0 {
		loadout = {
			primary   = game.WEAPON_AK,
			secondary = game.WEAPON_USP,
			armor     = true,
		}
	}
	if cli.weapon != "" {
		index := -1
		for weapon, i in game.WEAPONS {
			if weapon.name == cli.weapon do index = i
		}
		switch {
		case index < 0:
			log.warnf("No weapon named {:q}", cli.weapon)
		case index == game.WEAPON_KNIFE:
		// always owned; default_weapon_index holds it up
		case cli.bench <= 0 && !cli.practice && !game.weapon_allowed(index, team):
			log.warnf("Weapon {:q} is not for team {}", cli.weapon, team)
		case game.WEAPONS[index].slot == 0:
			loadout.primary = i8(index)
		case:
			loadout.secondary = i8(index)
		}
	}
	return loadout
}

// What a fresh life holds, from the loadout. Respawning goes through here too,
// so --weapon survives dying -- which is the only reason it is usable for
// looking at a viewmodel while the bots shoot back.
default_weapon_index :: proc() -> int {
	if cli.weapon == "knife" do return game.WEAPON_KNIFE
	return game.loadout_spawn_index(player.loadout)
}

init_weapons :: proc() {
	weapon_state = {}
	weapon_state.index = default_weapon_index()
	refill_all_ammo()
	// Last, so it reads the weapon that was just drawn. A no-op without a scope.
	if cli.zoom do weapon_toggle_zoom()

	log.infof("Weapons: {} ({} selected)", game.WEAPON_COUNT, current_weapon().name)
}

// The scope, a toggle on weapons that have one. Zoom is a lens fact: the
// projection, the light culling and the shadow cascades all read the camera's
// fov, so setting it here is the whole render-side job. The wire side rides
// build_local_input as a held button.
weapon_toggle_zoom :: proc() {
	if current_weapon().zoom_fov <= 0 do return
	weapon_state.zoom_active = !weapon_state.zoom_active
	camera.fov_horizontal = weapon_state.zoom_active ? current_weapon().zoom_fov : DEFAULT_FOV
}

// Anything that takes the weapon out of the hands drops the scope with it.
reset_zoom :: proc() {
	if !weapon_state.zoom_active do return
	weapon_state.zoom_active = false
	camera.fov_horizontal = DEFAULT_FOV
}

select_weapon :: proc(index: int) {
	if index < 0 || index >= game.WEAPON_COUNT do return
	reset_zoom()
	if index == weapon_state.index do return

	weapon_state.index = index
	weapon_state.cooldown = game.SWITCH_COOLDOWN // brief settle so switching is not a free shot
	weapon_state.draw_left = game.SWITCH_COOLDOWN
	weapon_state.recoil = 0
	// Rounds already chambered stay chambered, but the reload itself is lost --
	// swapping out mid-magazine to skip the wait is not a trade worth allowing.
	weapon_state.reload_left = 0
	// A different weapon is a different pattern, mirroring select_pawn_weapon.
	game.spray_track_reset(&weapon_state.spray)
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
	// Reloading lowers the weapon; the burst is over, as on the server.
	game.spray_track_reset(&weapon_state.spray)
	return true
}

@(private = "file")
finish_reload :: proc() {
	weapon := current_weapon()
	ammo := &weapon_ammo[weapon_state.index]

	take := min(weapon.mag_size - ammo.mag, ammo.reserve)
	ammo.mag += take
	// The range trains aim, not economy: magazines cycle, reserve never drains.
	if !practice_active() {
		ammo.reserve -= take
	}
}

// -------------------------------------------------------------------- firing

// The client's half of the shared firing rule, with the local context filled
// in. Asked by both the cosmetic fire control below and by what goes on the
// wire, so the muzzle stays dark exactly where the server would refuse the
// shot -- and so a trigger that does reach the server means something.
//
// Offline there is no match to be outside of: the benchmark fires without a
// cursor and without a connection, and measuring its muzzle flashes is the
// whole point of it.
local_fire_block :: proc() -> game.Fire_Block {
	if local_sim_active() do return game.pawn_fire_block(.Live, player)
	if !net_client.joined do return .Not_In_Match
	return game.pawn_fire_block(net_client.phase, player)
}

// Fire control runs on real time rather than the fixed tick, and shots are
// tested against the interpolated world -- what is on screen is what gets hit.
// A server would call this lag compensation; locally it is simply the truth.
update_weapon :: proc(dt: f32, alpha: f32) {
	weapon_state.cooldown = max(weapon_state.cooldown - dt, 0)
	weapon_state.flash = max(weapon_state.flash - dt, 0)
	weapon_state.hit_marker = max(weapon_state.hit_marker - dt, 0)
	weapon_state.recoil = max(weapon_state.recoil - dt * RECOIL_RECOVERY, 0)
	weapon_state.draw_left = max(weapon_state.draw_left - dt, 0)

	// The burst cools off the way the server's does (tick_pawn_weapon), just
	// on frame time -- the linear finisher lands both ends on an exact 0
	// within a tick of each other.
	game.spray_track_decay(&weapon_state.spray, current_weapon().spray, dt)

	update_viewmodel(dt)

	if weapon_state.reload_left > 0 {
		weapon_state.reload_left -= dt
		if weapon_state.reload_left <= 0 {
			weapon_state.reload_left = 0
			finish_reload()
		}
	}

	// While the buy menu is up, number keys navigate it, not the holster.
	if !buy_menu.open {
		for key, slot in SLOT_KEYS {
			if !key_pressed(key) do continue
			if index := game.loadout_weapon_in_slot(player.loadout, slot); index >= 0 {
				select_weapon(index)
			}
		}
	}

	// A corpse holds neither trigger nor magazine, and neither does anybody
	// still waiting for the clock to start. The cursor stays a separate
	// question: a loose one means a menu owns the mouse, which is context
	// rather than a rule of the match. The benchmark holds a trigger without
	// a cursor to grab.
	if local_fire_block() != .None || (!input.cursor_grabbed && !bench_active()) {
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
		weapon_state.cooldown = game.DRY_FIRE_COOLDOWN
		return
	}

	fire(alpha)
	weapon_state.cooldown = weapon.fire_interval
}

Shot_Result :: struct {
	hit:    bool,
	point:  [3]f32,
	normal: [3]f32,
	target: int, // -1 when the world was hit; a bot index in the benchmark, a remote index online
	group:  game.Hit_Group, // where on the target the ray landed; None for the world
}

// The ray starts at the eye and runs along the view direction, not from the
// muzzle. That is what makes the crosshair tell the truth: a shot leaving the
// barrel would be offset from where the player is looking and would miss at
// close range.
//
// Online this trace is cosmetic -- markers and decals now, the server's word
// on damage later. It runs against the interpolated positions the player is
// actually looking at, so the feedback agrees with the screen.
trace_shot :: proc(alpha: f32, direction: [3]f32) -> Shot_Result {
	weapon := current_weapon()
	origin := player_eye()

	result := Shot_Result {
		target = -1,
	}

	best_t := weapon.range
	found := false

	if hit, ok := physics.grid_raycast(&gs.grid, origin, direction, best_t); ok {
		best_t = hit.t
		result.point = hit.point
		result.normal = hit.normal
		found = true
	}

	// Targets are tested after the world but against the tightened range, so
	// one standing in front of a wall wins and one behind it does not.
	if local_sim_active() {
		for i in 0 ..< BOT_COUNT {
			pawn := bot_pawn(i)
			if !pawn.alive do continue

			box := bot_hit_box(pawn, alpha)
			hit, ok := physics.ray_aabb(origin, direction, box, best_t)
			if !ok do continue

			best_t = hit.t
			result.point = hit.point
			result.normal = hit.normal
			result.target = i
			result.group = game.hit_group_from_height(hit.point.z, box.min.z, box.max.z - box.min.z)
			found = true
		}
	} else {
		for i in 0 ..< remote.drawn_count {
			d := &remote.drawn[i]

			box := remote_target_box(d)
			hit, ok := physics.ray_aabb(origin, direction, box, best_t)
			if !ok do continue

			best_t = hit.t
			result.point = hit.point
			result.normal = hit.normal
			result.target = i
			result.group = game.hit_group_from_height(hit.point.z, box.min.z, box.max.z - box.min.z)
			found = true
		}
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

	streak_start: [3]f32
	if !weapon.melee {
		weapon_state.flash = MUZZLE_FLASH_TIME

		// The flash lights the surroundings for a moment. It is a real light, so
		// walls near the muzzle brighten the way they should.
		muzzle := muzzle_world_position()
		add_transient_light(muzzle, {1.0, 0.82, 0.5}, 26, 7, MUZZLE_FLASH_TIME)

		// The streak starts near the muzzle rather than at it -- tracer_origin
		// holds it at the same place on screen through any lens, which the light
		// above has no reason to care about.
		streak_start = tracer_origin()
	}

	// The same spray step and pellet pattern the server traces, from the raw
	// camera angles -- the already-accepted cosmetic divergence from the
	// quantized wire ones. The stance cone is drawn from the local rng: in the
	// practice range that sample is the truth, online the server's own draws
	// decide the damage.
	spray_yaw, spray_pitch := camera.yaw, camera.pitch
	inacc := f32(0)
	if !weapon.melee {
		pre := weapon_state.spray.progress
		// Offline this roll is the truth; online it is a placeholder the next
		// snapshot's seed corrects -- masked by the deterministic prefix. No
		// pattern, no seed: knife/nova/awp bursts leave the rng untouched.
		burst_seed := u32(0)
		if pre == 0 && weapon.spray.climb_shots > 0 {
			burst_seed = rand.uint32(cosmetic_rng)
		}
		off := game.spray_track_shot(&weapon_state.spray, weapon.spray, weapon.mag_size, burst_seed)
		spray_yaw += off.x
		spray_pitch = clamp(spray_pitch + off.y, -game.SPRAY_MAX_PITCH, game.SPRAY_MAX_PITCH)
		inacc = game.inaccuracy_degrees(weapon, player^, weapon_state.zoom_active, pre)
		viewpunch_note_shot()
	}

	count := max(weapon.pellets, 1)
	any_hit := false
	killed := false
	for i in 0 ..< count {
		yaw, pitch := spray_yaw, spray_pitch
		if inacc > 0 {
			j := game.inaccuracy_offset(cosmetic_rng, inacc)
			yaw += j.x
			pitch = clamp(pitch + j.y, -game.SPRAY_MAX_PITCH, game.SPRAY_MAX_PITCH)
		}
		dir := game.pellet_dir(yaw, pitch, i, weapon.spread)
		shot := trace_shot(alpha, dir)

		// The tracer flies to wherever the trace ended: the impact when it hit,
		// the end of the weapon's reach when it did not. At the weapon's own
		// speed, which is what tells a pistol shot from a rifle round in the air.
		if !weapon.melee {
			end := shot.hit ? shot.point : player_eye() + dir * weapon.range
			add_tracer(streak_start, end, weapon.tracer_speed)
		}

		if !shot.hit do continue

		if shot.target >= 0 {
			any_hit = true
			if local_sim_active() {
				// The server's damage math, mirrored so the range teaches
				// the real numbers.
				dmg := weapon.damage
				pen := weapon.armor_pen
				if !weapon.melee {
					dmg = game.scaled_damage(weapon.damage, shot.group)
					if game.hit_group_bypasses_armor(shot.group) do pen = 1
				}
				if local_damage_bot(shot.target, dmg, pen) {
					killed = true
				}
			}
			continue
		}

		// Decals only go on the world, and only from something that leaves a
		// hole. Seeds spaced per pellet so the nine holes get distinct edges.
		if weapon.melee do continue
		seed := f32(weapon_state.shots * game.MAX_PELLETS + i) * 0.6180339887
		add_decal(shot.point, shot.normal, seed - math.floor(seed))
	}

	if any_hit {
		// One marker per pull: the stat stays "pulls that connected".
		weapon_state.hits += 1
		weapon_state.hit_marker = HIT_MARKER_TIME
		// Online the server decides whether it killed; reconcile turns the
		// marker red when the confirmation arrives.
		weapon_state.hit_killed = local_sim_active() ? killed : false
	}
}

hit_marker_alpha :: proc() -> f32 {
	if weapon_state.hit_marker <= 0 do return 0
	return weapon_state.hit_marker / HIT_MARKER_TIME
}

// ----------------------------------------------------------------- viewmodel
//
// The models arrive posed in view space -- the scenes they come from are built
// around a camera at the origin -- so placing one is a matter of hanging it off
// the camera basis and then moving it the way a held weapon moves.
//
// None of what follows is animation in the sense the source assets mean it: the
// mesh is rigid and every bit of motion here is procedural. What it buys is the
// part players actually read as "the weapon is being held by someone": it lags
// behind the view, rocks with the stride, dips when the weapon is put away and
// tips over during a reload.

// How far the weapon lags behind a turn, in metres per degree per second, and
// how quickly it catches up. The cap keeps a flick from throwing the weapon off
// the side of the screen.
SWAY_PER_DEGREE :: 0.0016
SWAY_RECOVERY :: 11.0
SWAY_LIMIT :: 0.03

// Walking bob. The vertical component runs at twice the horizontal one, which
// is what makes it read as a stride rather than as a wobble.
BOB_SPEED :: 8.0
BOB_SIDE :: 0.012
BOB_RISE :: 0.008
// Speed that earns the full amount, near enough the run speed that walking
// bobs less without the amplitude ever being tied to the exact top speed.
BOB_FULL_SPEED :: 5.0
BOB_SETTLE :: 6.0

// How far the weapon drops out of frame while being swapped. It has to clear
// the bottom of the screen inside SWITCH_COOLDOWN, so this is a distance, not a
// fraction.
DRAW_DROP :: 0.28

// Reload takes the weapon down and rolls it toward the off hand -- the fixed
// mesh has no magazine that can move, so the whole weapon does the moving.
RELOAD_DROP :: 0.14
RELOAD_ROLL :: 0.09

// Everything that displaces the viewmodel without the simulation knowing.
Viewmodel_Motion :: struct {
	sway:       [2]f32, // yaw and pitch lag, metres
	bob_phase:  f32,
	bob_weight: f32, // eases in and out with the player's speed
}

viewmodel: Viewmodel_Motion

// The view turned. Told rather than measured, the same way view.odin is told
// about steps and landings -- the mouse delta is consumed in one place and this
// is a consequence of it, not a second reading of the input.
viewmodel_note_look :: proc(dx, dy: f32) {
	// Scaled by the same constant the camera turns by, so the sway matches the
	// turn at any sensitivity.
	scale := camera.sensitivity * CS_DEGREES_PER_COUNT * SWAY_PER_DEGREE
	viewmodel.sway.x = clamp(viewmodel.sway.x - dx * scale, -SWAY_LIMIT, SWAY_LIMIT)
	viewmodel.sway.y = clamp(viewmodel.sway.y - dy * scale, -SWAY_LIMIT, SWAY_LIMIT)
}

// Called once per rendered frame, like view_update -- this is what the eye sees
// right now and should be as smooth as the display can show.
@(private = "file")
update_viewmodel :: proc(dt: f32) {
	if dt <= 0 do return

	viewmodel.sway -= viewmodel.sway * (1 - math.exp(-SWAY_RECOVERY * dt))

	velocity := player.body.velocity
	speed := math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
	target := player.body.on_ground ? min(speed / BOB_FULL_SPEED, 1) : 0
	viewmodel.bob_weight += (target - viewmodel.bob_weight) * (1 - math.exp(-BOB_SETTLE * dt))

	// Multiplied by the weight, so the stride slows to a stop with the player
	// instead of ticking on under a still weapon.
	viewmodel.bob_phase += dt * BOB_SPEED * viewmodel.bob_weight
	if viewmodel.bob_phase > math.TAU do viewmodel.bob_phase -= math.TAU
}

// 0 while the weapon is out, 1 at the bottom of the swap.
@(private = "file")
draw_progress :: proc() -> f32 {
	if weapon_state.draw_left <= 0 do return 0
	// A half sine: down and back up inside the one cooldown, with no corner at
	// the turn.
	t := weapon_state.draw_left / game.SWITCH_COOLDOWN
	return math.sin(clamp(t, 0, 1) * math.PI)
}

// Where the weapon sits this frame, and the axes it is oriented along.
@(private = "file")
weapon_origin :: proc() -> (origin, right, forward, up: [3]f32) {
	weapon := current_weapon()
	right, forward, up = camera_basis()

	offset := weapon.view_offset
	// recoil pushes the weapon back along its own barrel and tips it up
	kick := weapon_state.recoil * weapon.recoil_kick

	bob_side := math.sin(viewmodel.bob_phase) * BOB_SIDE * viewmodel.bob_weight
	bob_rise := math.cos(viewmodel.bob_phase * 2) * BOB_RISE * viewmodel.bob_weight

	reload := reload_progress()
	// One arc down and back, so the weapon is lowest halfway through the reload
	reload_curve := reload > 0 ? math.sin(reload * math.PI) : 0

	swap := draw_progress()

	offset.x += viewmodel.sway.x + bob_side + reload_curve * RELOAD_ROLL
	offset.y += -kick
	// The last term is the landing dip the camera already carries, applied
	// again to the weapon so it settles a moment after the view does.
	offset.z +=
		viewmodel.sway.y +
		bob_rise +
		kick * 0.4 -
		reload_curve * RELOAD_DROP -
		swap * DRAW_DROP +
		view.land_offset * 0.5

	origin = camera.position + right * offset.x + forward * offset.y + up * offset.z
	return
}

muzzle_world_position :: proc() -> [3]f32 {
	m := current_weapon().muzzle
	origin, right, forward, up := weapon_origin()
	return origin + right * m.x + forward * m.y + up * m.z
}

// Where a tracer leaves the weapon. The muzzle is centimetres of world offset,
// but where a streak *starts* is a screen fact: the 13 cm that read as "out of
// the barrel" at 90 degrees put the start two thirds of the way to the edge of a
// 30 degree scope and all but on its bottom rim -- with the weapon not even
// drawn there to explain it. Scaling the lateral part with the lens puts the
// start back on the same pixel whatever the fov.
//
// The forward part is left alone: how far in front of the eye the barrel ends is
// a depth, not a screen quantity, and the streak needs that parallax or it
// collapses to a dot on the crosshair.
tracer_origin :: proc() -> [3]f32 {
	right, forward, up := camera_basis()
	offset := muzzle_world_position() - camera.position

	// Both lenses measured the way the player sees them, the scope's mask
	// included: it crops the width to a square, so the two axes do not shrink by
	// the same amount.
	w, h := visible_half_tangents(camera.fov_horizontal, weapon_state.zoom_active)
	w0, h0 := visible_half_tangents(DEFAULT_FOV, false)

	// The basis is orthonormal, so taking the offset apart and putting it back
	// together is exact.
	return(
		camera.position +
		right * (linalg.dot(offset, right) * w / w0) +
		forward * linalg.dot(offset, forward) +
		up * (linalg.dot(offset, up) * h / h0) \
	)
}

// The weapon mesh, plus the one part of it still made of blocks.
submit_viewmodel :: proc() {
	// Scoped in, the scope overlay is the whole picture.
	if weapon_state.zoom_active do return

	weapon := current_weapon()
	origin, right, forward, up := weapon_origin()

	add_view_model(weapon.model, prop_transform_oriented(origin, 1, right, forward, up))

	// The flash is a block that lights up rather than a sprite, which keeps it
	// in the same renderer as everything else.
	if weapon_state.flash > 0 {
		strength := weapon_state.flash / MUZZLE_FLASH_TIME
		muzzle := muzzle_world_position()
		size := [3]f32{0.06, 0.09, 0.06} * (0.6 + 0.4 * strength)

		add_view_prop(
			prop_transform_oriented(muzzle, size, right, forward, up),
			{1.0, 0.86, 0.55},
			roughness = 1.0,
			emissive = 14 * strength,
		)
	}
}
