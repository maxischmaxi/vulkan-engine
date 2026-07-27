package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "physics"

// Targets that wander the map. They exist to be shot at, so their behaviour is
// deliberately minimal: pick a direction, walk until something stops you, pick
// another. No navmesh, no pathfinding -- the collision response already keeps
// them out of walls.

BOT_COUNT :: 12
BOT_RADIUS :: 0.25
BOT_HEIGHT :: 1.1
BOT_SPEED :: 3.2
BOT_STEP :: 0.35

BOT_RETARGET_MIN :: 1.5
BOT_RETARGET_MAX :: 4.0
BOT_RESPAWN_DELAY :: 1.0

BOT_HEALTH :: 100

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

Bot :: struct {
	body:          physics.Body,
	prev_position: [3]f32,
	color:         [3]f32,
	wish_dir:      [2]f32,
	retarget_in:   f32,
	alive:         bool,
	respawn_in:    f32,
	health:        int,
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

bots: [BOT_COUNT]Bot
bot_rng: rand.Generator

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

	for &bot, i in bots {
		bot.body = physics.Body {
			radius = BOT_RADIUS,
			height = BOT_HEIGHT,
			step   = BOT_STEP,
		}
		// spread across the hue circle so no two are easily confused
		hue := f32(i) / f32(BOT_COUNT)
		bot.color = hue_to_rgb(hue)
		respawn_bot(&bot)
	}

	log.infof("Bots: {} wandering", BOT_COUNT)
}

// Saturated colours so the targets read clearly against sandstone.
@(private = "file")
hue_to_rgb :: proc(h: f32) -> [3]f32 {
	r := abs(h * 6 - 3) - 1
	g := 2 - abs(h * 6 - 2)
	b := 2 - abs(h * 6 - 4)
	return {clamp(r, 0, 1) * 0.85 + 0.1, clamp(g, 0, 1) * 0.85 + 0.1, clamp(b, 0, 1) * 0.85 + 0.1}
}

bot_aabb :: proc(bot: Bot) -> physics.Aabb {
	return physics.body_aabb(bot.body)
}

// Picks a room, picks a point in it, drops a short ray onto whatever is under
// that point, and checks the bot fits there.
//
// The ray starts just above the room's own floor rather than above the map. A
// map with roofs on it answers a ray from the sky with a roof, and bots would
// spend the round patrolling the top of the tunnels.
find_bot_spawn :: proc(bot: ^Bot) -> ([3]f32, bool) {
	probe := bot.body

	for attempt in 0 ..< 64 {
		area := MAP_SPAWN_AREAS[rand.int_max(len(MAP_SPAWN_AREAS), bot_rng)]

		// The first few attempts sample the room; after that, its centre, which
		// is open by construction in every room on the list.
		x := (area.min.x + area.max.x) * 0.5
		y := (area.min.y + area.max.y) * 0.5
		if attempt < 48 {
			x = rand.float32_range(area.min.x, area.max.x, bot_rng)
			y = rand.float32_range(area.min.y, area.max.y, bot_rng)
		}

		z, found := physics.ground_below(
			{x, y, area.floor + BOT_PROBE_UP},
			world_collision,
			BOT_PROBE_UP + BOT_PROBE_DOWN,
		)
		if !found do continue

		// lifted a hair so resting on the surface is not counted as inside it
		candidate := [3]f32{x, y, z + 0.01}
		if physics.overlaps_any(physics.body_aabb_at(probe, candidate), world_collision) {
			continue
		}
		return candidate, true
	}
	return {}, false
}

respawn_bot :: proc(bot: ^Bot) {
	position, ok := find_bot_spawn(bot)
	if !ok {
		log.warn("No free spawn found for a bot, retrying next tick")
		bot.respawn_in = 0.5
		bot.alive = false
		return
	}

	bot.body.position = position
	bot.body.velocity = {}
	bot.body.on_ground = false
	bot.prev_position = position
	bot.alive = true
	bot.respawn_in = 0
	bot.health = BOT_HEALTH
	bot.fire_cooldown = 0
	bot.seen_time = 0
	// Rolled per life rather than shared, so a group coming round a corner does
	// not fire as one volley.
	bot.reaction = rand.float32_range(BOT_REACTION_MIN, BOT_REACTION_MAX, bot_rng)
	bot.strafe = rand.float32(bot_rng) < 0.5 ? -1 : 1
	pick_bot_direction(bot)
}

@(private = "file")
pick_bot_direction :: proc(bot: ^Bot) {
	angle := rand.float32_range(0, 2 * math.PI, bot_rng)
	bot.wish_dir = {math.cos(angle), math.sin(angle)}
	bot.retarget_in = rand.float32_range(BOT_RETARGET_MIN, BOT_RETARGET_MAX, bot_rng)
}

tick_bots :: proc(dt: f32) {
	for &bot in bots {
		if !bot.alive {
			bot.respawn_in -= dt
			if bot.respawn_in <= 0 do respawn_bot(&bot)
			continue
		}

		bot.prev_position = bot.body.position

		engaged := tick_bot_combat(&bot, dt)
		if !engaged {
			bot.retarget_in -= dt
			if bot.retarget_in <= 0 do pick_bot_direction(&bot)
		}

		before := bot.body.position
		physics.step_move(
			&bot.body,
			world_collision,
			bot.wish_dir.x * BOT_SPEED * dt,
			bot.wish_dir.y * BOT_SPEED * dt,
		)
		physics.apply_gravity(&bot.body, world_collision, GRAVITY, dt)

		// Walked into something: turning immediately is what keeps them from
		// grinding along a wall for the rest of their timer. A bot in a fight
		// keeps its target and circles the other way instead, because giving up
		// the chase at the first doorframe looks like it lost interest.
		moved := physics.horizontal_distance(bot.body.position, before)
		if moved < BOT_SPEED * dt * 0.5 {
			if engaged {
				bot.strafe = -bot.strafe
			} else {
				pick_bot_direction(&bot)
			}
		}

		// A bot that finds a hole in the map should not fall forever.
		if bot.body.position.z < -20 do kill_bot(&bot, respawn_delay = 0.1)
	}
}

// ------------------------------------------------------------------- combat

@(private = "file")
bot_eye :: proc(bot: Bot) -> [3]f32 {
	return bot.body.position + {0, 0, BOT_HEIGHT * 0.85}
}

// Distance to the player and whether anything is in the way. The same ray the
// player's own shots use, run in the other direction.
@(private = "file")
bot_sees_player :: proc(bot: Bot) -> (dist: f32, visible: bool) {
	if !player.alive do return 0, false

	origin := bot_eye(bot)
	delta := player_tick_eye() - origin
	dist = linalg.length(delta)
	if dist > BOT_VIEW_RANGE || dist < 0.001 do return dist, false

	// The margin keeps a wall the player is standing flush against from
	// counting as cover.
	if hit, ok := physics.ray_scene(origin, delta / dist, world_collision, dist); ok {
		if hit.t < dist - 0.3 do return dist, false
	}
	return dist, true
}

// Returns whether the bot is in a fight, which is what decides how it moves.
@(private = "file")
tick_bot_combat :: proc(bot: ^Bot, dt: f32) -> bool {
	bot.fire_cooldown = max(bot.fire_cooldown - dt, 0)

	dist, visible := bot_sees_player(bot^)
	bot.sees_player = visible
	if !visible {
		bot.seen_time = 0
		return false
	}

	bot.seen_time += dt

	to_player := [2]f32 {
		player.body.position.x - bot.body.position.x,
		player.body.position.y - bot.body.position.y,
	}
	flat := linalg.length(to_player)
	if flat > 0.001 {
		toward := to_player / flat
		// Close the distance, then circle. A bot that walks all the way in is
		// free damage; one that stands still at range is a target.
		bot.wish_dir = flat > BOT_ENGAGE_RANGE ? toward : [2]f32{-toward.y, toward.x} * bot.strafe
	}

	// Bringing the weapon round takes a moment. Without it a bot that steps out
	// of cover lands its first shot on the same tick, which reads as cheating
	// rather than as a firefight.
	if bot.seen_time < bot.reaction || bot.fire_cooldown > 0 do return true

	bot.fire_cooldown = BOT_FIRE_INTERVAL
	// Without sound this flash is the only clue where the shot came from.
	add_transient_light(bot_eye(bot^), {1.0, 0.82, 0.5}, 18, 6, MUZZLE_FLASH_TIME)

	// Accuracy falls off with distance rather than being one flat roll: the
	// difference between a bot across the map and one in your face is the whole
	// reason to close ground or break line of sight.
	chance := BOT_ACCURACY * clamp(1 - dist / BOT_VIEW_RANGE, 0.25, 1)
	if rand.float32(bot_rng) < chance {
		damage_player(BOT_DAMAGE, bot.body.position)
	}
	return true
}

// Returns whether this was the killing blow, which the hit marker colours.
damage_bot :: proc(bot: ^Bot, amount: int) -> bool {
	if !bot.alive do return false

	bot.health -= amount
	if bot.health > 0 do return false

	kill_bot(bot)
	player.kills += 1
	return true
}

bots_alive :: proc() -> int {
	count := 0
	for bot in bots {
		if bot.alive do count += 1
	}
	return count
}

kill_bot :: proc(bot: ^Bot, respawn_delay: f32 = BOT_RESPAWN_DELAY) {
	bot.alive = false
	bot.respawn_in = respawn_delay
	bot.seen_time = 0
}

// Bots are drawn where they appear to be this frame, not where the last tick
// left them -- and the same interpolated position is what shots are tested
// against, so what you see is what you hit.
bot_render_position :: proc(bot: Bot, alpha: f32) -> [3]f32 {
	return linalg.lerp(bot.prev_position, bot.body.position, alpha)
}

// The box a shot has to intersect. Built from the interpolated position for the
// same reason.
bot_hit_box :: proc(bot: Bot, alpha: f32) -> physics.Aabb {
	position := bot_render_position(bot, alpha)
	return physics.body_aabb_at(bot.body, position)
}

// Hands every living bot to the prop renderer.
submit_bots :: proc(alpha: f32) {
	for bot in bots {
		if !bot.alive do continue

		position := bot_render_position(bot, alpha)
		center := position + [3]f32{0, 0, BOT_HEIGHT * 0.5}
		size := [3]f32{BOT_RADIUS * 2, BOT_RADIUS * 2, BOT_HEIGHT}

		add_world_prop(prop_transform(center, size), bot.color, roughness = 0.7)
	}
}
