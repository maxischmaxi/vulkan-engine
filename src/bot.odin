package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "game"
import "physics"

// Targets that wander the map. The bodies are pawns in the shared game state
// -- the same struct the player is -- so a shot, a snapshot or a server loop
// treats everyone alike. What stays here is the brain: where a bot wants to
// go, whom it sees, when it fires. The brain will move to the server; the
// pawns will stay.

BOT_COUNT :: 12
BOT_RADIUS :: 0.25
BOT_HEIGHT :: 1.1
BOT_SPEED :: 3.2
BOT_STEP :: 0.35

BOT_RETARGET_MIN :: 1.5
BOT_RETARGET_MAX :: 4.0
BOT_RESPAWN_DELAY :: 1.0

// How far a bot can pick the player out, and how long it takes to bring a
// weapon round once it has. The delay is what turns a corner into a duel
// instead of an execution.
//
// Range is deliberately well short of the 104 m map: bots close on whoever they
// can see, so a range that covered mid end to end had all twelve converging on
// the player at once, every time.
BOT_VIEW_RANGE :: 30.0
BOT_REACTION_MIN :: 0.25
BOT_REACTION_MAX :: 0.60

// Deliberate shots rather than suppressing fire. Twelve bots converging on one
// player add up fast: at half this interval, standing still at spawn killed the
// player in five seconds, which is not a firefight, it is weather.
BOT_FIRE_INTERVAL :: 0.9
BOT_DAMAGE :: 15

// Hit chance at point-blank range, falling off to a quarter of it at the far
// edge of BOT_VIEW_RANGE.
BOT_ACCURACY :: 0.45

// Inside this the bot stops closing and strafes, so a firefight is not two
// boxes ending up inside each other.
BOT_ENGAGE_RANGE :: 8.0

// The player holds pawn slot zero; the bots line up behind it.
BOT_FIRST :: 1
#assert(BOT_FIRST + BOT_COUNT <= game.MAX_PAWNS)

// Everything a bot is beyond its body. Parallel to the pawn slots rather than
// embedded in them, because the pawn goes over the wire and the brain never
// does.
Bot_Brain :: struct {
	wish_dir:      [2]f32,
	retarget_in:   f32,
	// Combat. seen_time counts how long the player has been in view, which is
	// what the reaction delay is measured against.
	fire_cooldown: f32,
	seen_time:     f32,
	reaction:      f32,
	// The result of this tick's line-of-sight ray, kept so the radar can read it
	// instead of casting its own. Twelve rays per tick is a fixed cost; twelve
	// per frame was an uncapped one.
	sees_player:   bool,
	strafe:        f32, // +1 or -1, which way it circles once in range
}

brains: [BOT_COUNT]Bot_Brain
bot_rng: rand.Generator

bot_pawn :: proc(index: int) -> ^game.Pawn {
	return &gs.pawns[BOT_FIRST + index]
}

// How far above a room's own floor the spawn probe starts, and how far below it
// looks. Enough to find a crate to stand on, nowhere near enough to reach the
// floor of a room stacked over this one.
BOT_PROBE_UP :: 2.0
BOT_PROBE_DOWN :: 3.0

init_bots :: proc() {
	// Deterministic by default: the same seed gives the same wandering, which
	// makes a bug reproducible instead of a story about what happened once.
	bot_rng = rand.default_random_generator()

	// Before the first spawn rather than after it: a room that has been sealed
	// off by a stray brush shows up here as one line, and as twelve retrying
	// bots otherwise.
	verify_spawn_areas()
	verify_player_spawn()

	for i in 0 ..< BOT_COUNT {
		respawn_bot(i, game.MAP_SPAWN_AREAS)
	}

	log.infof("Bots: {} wandering", BOT_COUNT)
}

// Saturated colours so the targets read clearly against sandstone. Derived
// from the slot, so a respawn keeps its colour; team colours replace this once
// teams exist.
bot_color :: proc(index: int) -> [3]f32 {
	h := f32(index) / f32(BOT_COUNT)
	r := abs(h * 6 - 3) - 1
	g := 2 - abs(h * 6 - 2)
	b := 2 - abs(h * 6 - 4)
	return {clamp(r, 0, 1) * 0.85 + 0.1, clamp(g, 0, 1) * 0.85 + 0.1, clamp(b, 0, 1) * 0.85 + 0.1}
}

// Picks a room, picks a point in it, drops a short ray onto whatever is under
// that point, and checks the bot fits there.
//
// The ray starts just above the room's own floor rather than above the map. A
// map with roofs on it answers a ray from the sky with a roof, and bots would
// spend the round patrolling the top of the tunnels.
find_bot_spawn :: proc(probe: physics.Body, areas: []game.Spawn_Area) -> ([3]f32, bool) {
	for attempt in 0 ..< 64 {
		area := areas[rand.int_max(len(areas), bot_rng)]

		// The first few attempts sample the room; after that, its centre, which
		// is open by construction in every room on the list.
		x := (area.min.x + area.max.x) * 0.5
		y := (area.min.y + area.max.y) * 0.5
		if attempt < 48 {
			x = rand.float32_range(area.min.x, area.max.x, bot_rng)
			y = rand.float32_range(area.min.y, area.max.y, bot_rng)
		}

		z, found := physics.grid_ground_below(
			&gs.grid,
			{x, y, area.floor + BOT_PROBE_UP},
			BOT_PROBE_UP + BOT_PROBE_DOWN,
		)
		if !found do continue

		// lifted a hair so resting on the surface is not counted as inside it
		candidate := [3]f32{x, y, z + 0.01}
		if physics.grid_overlaps_any(&gs.grid, physics.body_aabb_at(probe, candidate)) {
			continue
		}
		return candidate, true
	}
	return {}, false
}

respawn_bot :: proc(index: int, areas: []game.Spawn_Area) {
	pawn := bot_pawn(index)
	brain := &brains[index]

	probe := physics.Body {
		radius = BOT_RADIUS,
		height = BOT_HEIGHT,
	}
	position, ok := find_bot_spawn(probe, areas)
	if !ok {
		log.warn("No free spawn found for a bot, retrying next tick")
		pawn.respawn_in = 0.5
		pawn.alive = false
		return
	}

	game.init_pawn(pawn, position, 0)
	pawn.is_bot = true
	// The bot hull, not the player's: the shared move code is hull-agnostic,
	// and the little boxes have been the game's look since they existed.
	pawn.body.radius = BOT_RADIUS
	pawn.body.height = BOT_HEIGHT
	pawn.body.step = BOT_STEP
	pawn.armor = 0

	brain^ = {}
	// Rolled per life rather than shared, so a group coming round a corner does
	// not fire as one volley.
	brain.reaction = rand.float32_range(BOT_REACTION_MIN, BOT_REACTION_MAX, bot_rng)
	brain.strafe = rand.float32(bot_rng) < 0.5 ? -1 : 1
	pick_bot_direction(brain)
}

pick_bot_direction :: proc(brain: ^Bot_Brain) {
	angle := rand.float32_range(0, 2 * math.PI, bot_rng)
	brain.wish_dir = {math.cos(angle), math.sin(angle)}
	brain.retarget_in = rand.float32_range(BOT_RETARGET_MIN, BOT_RETARGET_MAX, bot_rng)
}

tick_bots :: proc(dt: f32) {
	for i in 0 ..< BOT_COUNT {
		pawn := bot_pawn(i)
		brain := &brains[i]

		if !pawn.alive {
			pawn.respawn_in -= dt
			if pawn.respawn_in <= 0 do respawn_bot(i, game.MAP_SPAWN_AREAS)
			continue
		}

		engaged := tick_bot_combat(pawn, brain, dt)
		if !engaged {
			brain.retarget_in -= dt
			if brain.retarget_in <= 0 do pick_bot_direction(brain)
		}

		bot_wander_step(pawn, brain, dt, engaged)

		// A bot that finds a hole in the map should not fall forever.
		if pawn.body.position.z < -20 do kill_bot(i, respawn_delay = 0.1)
	}
}

// One movement step of the wander: the walk, the gravity, and the turn when a
// wall stops it. Shared between the bench tick and the practice tick.
bot_wander_step :: proc(pawn: ^game.Pawn, brain: ^Bot_Brain, dt: f32, engaged: bool) {
	pawn.prev_position = pawn.body.position

	before := pawn.body.position
	physics.grid_step_move(
		&pawn.body,
		&gs.grid,
		brain.wish_dir.x * BOT_SPEED * dt,
		brain.wish_dir.y * BOT_SPEED * dt,
	)
	physics.grid_apply_gravity(&pawn.body, &gs.grid, game.GRAVITY, dt)

	// Walked into something: turning immediately is what keeps them from
	// grinding along a wall for the rest of their timer. A bot in a fight
	// keeps its target and circles the other way instead, because giving up
	// the chase at the first doorframe looks like it lost interest.
	moved := physics.horizontal_distance(pawn.body.position, before)
	if moved < BOT_SPEED * dt * 0.5 {
		if engaged {
			brain.strafe = -brain.strafe
		} else {
			pick_bot_direction(brain)
		}
	}
}

// ------------------------------------------------------------------- combat

@(private = "file")
bot_eye :: proc(pawn: ^game.Pawn) -> [3]f32 {
	return pawn.body.position + {0, 0, BOT_HEIGHT * 0.85}
}

// Distance to the player and whether anything is in the way. The same ray the
// player's own shots use, run in the other direction.
@(private = "file")
bot_sees_player :: proc(pawn: ^game.Pawn) -> (dist: f32, visible: bool) {
	if !player.alive do return 0, false

	origin := bot_eye(pawn)
	delta := player_tick_eye() - origin
	dist = linalg.length(delta)
	if dist > BOT_VIEW_RANGE || dist < 0.001 do return dist, false

	// The margin keeps a wall the player is standing flush against from
	// counting as cover.
	if hit, ok := physics.grid_raycast(&gs.grid, origin, delta / dist, dist); ok {
		if hit.t < dist - 0.3 do return dist, false
	}
	return dist, true
}

// Returns whether the bot is in a fight, which is what decides how it moves.
@(private = "file")
tick_bot_combat :: proc(pawn: ^game.Pawn, brain: ^Bot_Brain, dt: f32) -> bool {
	brain.fire_cooldown = max(brain.fire_cooldown - dt, 0)

	dist, visible := bot_sees_player(pawn)
	brain.sees_player = visible
	if !visible {
		brain.seen_time = 0
		return false
	}

	brain.seen_time += dt

	to_player := [2]f32 {
		player.body.position.x - pawn.body.position.x,
		player.body.position.y - pawn.body.position.y,
	}
	flat := linalg.length(to_player)
	if flat > 0.001 {
		toward := to_player / flat
		// Close the distance, then circle. A bot that walks all the way in is
		// free damage; one that stands still at range is a target.
		brain.wish_dir =
			flat > BOT_ENGAGE_RANGE ? toward : [2]f32{-toward.y, toward.x} * brain.strafe
	}

	// Bringing the weapon round takes a moment. Without it a bot that steps out
	// of cover lands its first shot on the same tick, which reads as cheating
	// rather than as a firefight.
	if brain.seen_time < brain.reaction || brain.fire_cooldown > 0 do return true

	brain.fire_cooldown = BOT_FIRE_INTERVAL
	// Without sound this flash is the only clue where the shot came from.
	add_transient_light(bot_eye(pawn), {1.0, 0.82, 0.5}, 18, 6, MUZZLE_FLASH_TIME)

	// Accuracy falls off with distance rather than being one flat roll: the
	// difference between a bot across the map and one in your face is the whole
	// reason to close ground or break line of sight.
	chance := BOT_ACCURACY * clamp(1 - dist / BOT_VIEW_RANGE, 0.25, 1)
	if rand.float32(bot_rng) < chance {
		damage_player(BOT_DAMAGE, pawn.body.position)
	}
	return true
}

// Returns whether this was the killing blow, which the hit marker colours.
damage_bot :: proc(index: int, amount: int, armor_pen: f32 = 0) -> bool {
	pawn := bot_pawn(index)
	if !pawn.alive do return false

	if !game.damage_pawn(pawn, amount, armor_pen) do return false

	pawn.respawn_in = BOT_RESPAWN_DELAY
	brains[index].seen_time = 0
	player.kills += 1
	return true
}

bots_alive :: proc() -> int {
	count := 0
	for i in 0 ..< BOT_COUNT {
		if bot_pawn(i).alive do count += 1
	}
	return count
}

kill_bot :: proc(index: int, respawn_delay: f32 = BOT_RESPAWN_DELAY) {
	pawn := bot_pawn(index)
	if !pawn.alive do return
	game.kill_pawn(pawn)
	pawn.respawn_in = respawn_delay
	brains[index].seen_time = 0
}

// Pawns are drawn where they appear to be this frame, not where the last tick
// left them -- and the same interpolated position is what shots are tested
// against, so what you see is what you hit.
pawn_render_position :: proc(pawn: ^game.Pawn, alpha: f32) -> [3]f32 {
	return linalg.lerp(pawn.prev_position, pawn.body.position, alpha)
}

// The box a shot has to intersect. Built from the interpolated position for the
// same reason.
bot_hit_box :: proc(pawn: ^game.Pawn, alpha: f32) -> physics.Aabb {
	return physics.body_aabb_at(pawn.body, pawn_render_position(pawn, alpha))
}

// Hands every living bot to the character renderer. These pawns are simulated
// right here, so unlike a networked remote their velocity and aim need no
// deriving -- the body has both.
submit_bots :: proc(alpha: f32) {
	for i in 0 ..< BOT_COUNT {
		pawn := bot_pawn(i)
		if !pawn.alive do continue

		submit_character(
			{
				id = BOT_FIRST + i,
				position = pawn_render_position(pawn, alpha),
				yaw = pawn.yaw,
				pitch = pawn.pitch,
				velocity = pawn.body.velocity,
				height = pawn.body.height,
				team = pawn.team,
				weapon = pawn.weapon.index,
				crouching = pawn.crouching,
				health = u8(clamp(pawn.health, 0, 255)),
			},
		)
	}
}
