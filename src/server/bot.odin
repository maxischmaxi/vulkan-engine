package main

import "../game"
import "../physics"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

// The server's bot brains: the client's wander-and-duel AI, generalised from
// "the player" to "the nearest visible enemy pawn" -- which is what makes it
// indifferent to how many humans ever join. Movement goes through the same
// shared physics the humans use; only the decisions live here.

BOT_RADIUS :: 0.25
BOT_HEIGHT :: 1.1
BOT_SPEED :: 3.2
BOT_STEP :: 0.35

BOT_RETARGET_MIN :: 1.5
BOT_RETARGET_MAX :: 4.0

BOT_VIEW_RANGE :: 30.0
BOT_REACTION_MIN :: 0.25
BOT_REACTION_MAX :: 0.60

BOT_FIRE_INTERVAL :: 0.9
BOT_DAMAGE :: 15
BOT_ACCURACY :: 0.45
BOT_ENGAGE_RANGE :: 8.0

Bot_Brain :: struct {
	wish_dir:      [2]f32,
	retarget_in:   f32,
	fire_cooldown: f32,
	seen_time:     f32,
	reaction:      f32,
	strafe:        f32, // +1 or -1, which way it circles once in range
	target:        int, // pawn id it is duelling, -1 when wandering
}

// Indexed by pawn id; only the bot slots are ever touched.
brains: [game.MAX_PAWNS]Bot_Brain

spawn_bot :: proc(pawn_id: int, team: game.Team) {
	probe := physics.Body {
		radius = BOT_RADIUS,
		height = BOT_HEIGHT,
	}
	position, ok := server_find_spawn(probe)
	if !ok {
		log.warn("Server: no free spawn for a bot, retrying next tick")
		p := &sv.gs.pawns[pawn_id]
		p.active = true
		p.is_bot = true
		p.team = team
		p.alive = false
		p.respawn_in = 0.5
		return
	}
	spawn_bot_at(pawn_id, team, position, 0)
}

// The placed variant comp round starts use: no roaming probe, the caller
// already owns the spot.
spawn_bot_at :: proc(pawn_id: int, team: game.Team, position: [3]f32, yaw: f32) {
	p := &sv.gs.pawns[pawn_id]
	brain := &brains[pawn_id]

	game.init_pawn(p, position, yaw)
	p.is_bot = true
	p.team = team
	// The bot hull, not the player's -- the shared move code is hull-agnostic.
	p.body.radius = BOT_RADIUS
	p.body.height = BOT_HEIGHT
	p.body.step = BOT_STEP
	p.armor = 0

	brain^ = {
		reaction = rand.float32_range(BOT_REACTION_MIN, BOT_REACTION_MAX, sv.gs.rng),
		strafe   = rand.float32(sv.gs.rng) < 0.5 ? -1 : 1,
		target   = -1,
	}
	pick_direction(brain)
}

@(private = "file")
pick_direction :: proc(brain: ^Bot_Brain) {
	angle := rand.float32_range(0, 2 * math.PI, sv.gs.rng)
	brain.wish_dir = {math.cos(angle), math.sin(angle)}
	brain.retarget_in = rand.float32_range(BOT_RETARGET_MIN, BOT_RETARGET_MAX, sv.gs.rng)
}

tick_server_bots :: proc(dt: f32) {
	for pawn_id in 0 ..< game.MAX_PAWNS {
		p := &sv.gs.pawns[pawn_id]
		if !p.active || !p.is_bot do continue
		brain := &brains[pawn_id]

		if !p.alive {
			// Same rule as the humans: only modes with free respawns bring a
			// dead bot back -- comp bots stay down until the round resets them.
			p.respawn_in -= dt
			if p.respawn_in <= 0 && match.phase in match.mode.respawn_phases {
				spawn_bot(pawn_id, p.team)
			}
			continue
		}

		p.prev_position = p.body.position

		engaged := tick_bot_combat(pawn_id, p, brain, dt)
		if !engaged {
			brain.retarget_in -= dt
			if brain.retarget_in <= 0 do pick_direction(brain)
		}

		before := p.body.position
		physics.grid_step_move(
			&p.body,
			&sv.gs.grid,
			brain.wish_dir.x * BOT_SPEED * dt,
			brain.wish_dir.y * BOT_SPEED * dt,
		)
		physics.grid_apply_gravity(&p.body, &sv.gs.grid, game.GRAVITY, dt)

		// Walked into something: turn rather than grind along the wall. In a
		// fight, circle the other way instead of giving up the chase.
		moved := physics.horizontal_distance(p.body.position, before)
		if moved < BOT_SPEED * dt * 0.5 {
			if engaged {
				brain.strafe = -brain.strafe
			} else {
				pick_direction(brain)
			}
		}

		if p.body.position.z < -20 {
			game.kill_pawn(p)
			on_pawn_killed(-1, pawn_id)
		}
	}
}

@(private = "file")
bot_eye :: proc(p: ^game.Pawn) -> [3]f32 {
	return p.body.position + {0, 0, p.body.height * 0.85}
}

// The nearest living enemy with a clear line of sight, or nothing. Distance
// first, walls second: the ray only runs for candidates that could win.
@(private = "file")
acquire_target :: proc(p: ^game.Pawn) -> (target: int, dist: f32, visible: bool) {
	target = -1
	best := f32(BOT_VIEW_RANGE)
	origin := bot_eye(p)

	for &other, i in sv.gs.pawns {
		if !other.active || !other.alive || other.team == p.team do continue

		delta := game.eye_position(other) - origin
		d := linalg.length(delta)
		if d >= best || d < 0.001 do continue

		// The margin keeps a wall the target stands flush against from
		// counting as cover.
		if hit, ok := physics.grid_raycast(&sv.gs.grid, origin, delta / d, d); ok {
			if hit.t < d - 0.3 do continue
		}
		target = i
		best = d
	}
	return target, best, target >= 0
}

// Returns whether the bot is in a fight, which is what decides how it moves.
@(private = "file")
tick_bot_combat :: proc(pawn_id: int, p: ^game.Pawn, brain: ^Bot_Brain, dt: f32) -> bool {
	brain.fire_cooldown = max(brain.fire_cooldown - dt, 0)

	target_id, dist, visible := acquire_target(p)
	if !visible {
		brain.seen_time = 0
		brain.target = -1
		return false
	}

	// Switching targets restarts the reaction clock: a new enemy is a new
	// corner to come around.
	if target_id != brain.target {
		brain.target = target_id
		brain.seen_time = 0
	}
	brain.seen_time += dt

	target := &sv.gs.pawns[target_id]
	to_target := [2]f32 {
		target.body.position.x - p.body.position.x,
		target.body.position.y - p.body.position.y,
	}
	flat := linalg.length(to_target)
	if flat > 0.001 {
		toward := to_target / flat
		brain.wish_dir =
			flat > BOT_ENGAGE_RANGE ? toward : [2]f32{-toward.y, toward.x} * brain.strafe
		// The pawn faces its enemy, so the snapshot shows everyone where the
		// bot is looking.
		p.yaw = math.to_degrees(math.atan2(toward.y, toward.x))
	}

	if brain.seen_time < brain.reaction || brain.fire_cooldown > 0 do return true

	brain.fire_cooldown = BOT_FIRE_INTERVAL
	fired_this_tick[pawn_id] = true

	// Accuracy falls off with distance rather than being one flat roll; a
	// traced shot replaces this once bots hold real weapons.
	chance := BOT_ACCURACY * clamp(1 - dist / BOT_VIEW_RANGE, 0.25, 1)
	if rand.float32(sv.gs.rng) < chance {
		queue_damage(p.body.position, target_id, BOT_DAMAGE)
		if game.damage_pawn(target, BOT_DAMAGE) {
			sv.gs.pawns[pawn_id].kills += 1
			on_pawn_killed(pawn_id, target_id)
		}
	}
	return true
}
