package main

import "core:math/linalg"
import "game"
import "physics"
import "protocol"

// Remote entities -- the bots, and one day other humans -- drawn a fixed
// interpolation delay behind the newest snapshot, lerped between the two
// snapshots that bracket the render time. The delay buys smoothness and loss
// tolerance for a tenth of a second nobody aims by on a bot.

// Team colours shared with the menu's team cards, so the box you shoot is the
// colour you clicked.
TEAM_COLORS := [game.Team][3]f32 {
	.T  = {0.85, 0.55, 0.20},
	.CT = {0.30, 0.55, 0.90},
}

Remote_Draw :: struct {
	id:        int,
	team:      game.Team,
	is_bot:    bool,
	crouching: bool,
	position:  [3]f32,
	height:    f32,
	radius:    f32,
	yaw:       f32,
	pitch:     f32,
	weapon:    int,
	health:    u8,
	// Not on the wire -- the snapshot carries positions only. Derived from the
	// pair this entity is being interpolated between, which is the same two
	// numbers with the tick gap between them.
	velocity:  [3]f32,
}

Remote_View :: struct {
	render_tick:  f64, // drift-corrected interpolation clock, in server ticks
	initialized:  bool,
	drawn:        [game.MAX_PAWNS]Remote_Draw, // rebuilt every frame
	drawn_count:  int,
	fire_scanned: u32, // newest tick already checked for Fired flags
}

remote: Remote_View

// Advances the interpolation clock at real-time speed and nudges it toward
// the sweet spot behind the newest snapshot. A hard snap only after a real
// gap, so jitter never yanks the world around.
update_remote_clock :: proc(frame_dt: f32) {
	if !net_client.have_snapshot {
		remote.drawn_count = 0
		return
	}

	// ~94 ms at 64 Hz: two to three snapshot intervals of cushion.
	target := f64(net_client.latest_tick) - protocol.INTERP_TICKS
	if !remote.initialized {
		remote.render_tick = target
		remote.initialized = true
		// History before the join is nobody's gunfire to show.
		remote.fire_scanned = u32(max(target, 0))
	}

	remote.render_tick += f64(frame_dt) * game.TICK_RATE
	if abs(remote.render_tick - target) > 4 {
		remote.render_tick = target
	} else {
		remote.render_tick += (target - remote.render_tick) * 0.1
	}

	interpolate_remotes()
	scan_remote_fire()
}

@(private = "file")
entity_size :: proc(e: ^protocol.Snapshot_Entity) -> (radius, height: f32) {
	if .Is_Bot in e.flags {
		return BOT_RADIUS, BOT_HEIGHT
	}
	if .Crouching in e.flags {
		return game.PLAYER_RADIUS, game.CROUCH_HEIGHT
	}
	return game.PLAYER_RADIUS, game.PLAYER_HEIGHT
}

// Fills remote.drawn from the two snapshots bracketing the render time. Full
// snapshots make any pair workable; the lerp factor comes from the ticks the
// pair actually sits at.
@(private = "file")
interpolate_remotes :: proc() {
	remote.drawn_count = 0

	t0 := u32(remote.render_tick)

	// the newest valid snapshot at or below the render time
	from: ^protocol.Snapshot
	for back in 0 ..< u32(SNAPSHOT_CAP) {
		if back > t0 do break
		if s := snapshot_at(t0 - back); s != nil {
			from = s
			break
		}
	}
	if from == nil do return

	// the oldest valid snapshot after it
	to: ^protocol.Snapshot
	for tick := t0 + 1; tick <= net_client.latest_tick; tick += 1 {
		if s := snapshot_at(tick); s != nil {
			to = s
			break
		}
	}

	factor := f32(0)
	if to != nil && to.server_tick > from.server_tick {
		factor = f32(
			(remote.render_tick - f64(from.server_tick)) / f64(to.server_tick - from.server_tick),
		)
		factor = clamp(factor, 0, 1)
	}

	for id in 0 ..< game.MAX_PAWNS {
		if id not_in from.present do continue
		if id == net_client.pawn_id do continue // predicted, not interpolated
		e := &from.entities[id]
		if .Alive not_in e.flags do continue

		position := e.position
		yaw := e.yaw
		pitch := e.pitch
		velocity: [3]f32
		if to != nil && id in to.present {
			other := &to.entities[id]
			if .Alive in other.flags {
				position = linalg.lerp(e.position, other.position, factor)
				// Angles, not numbers: lerping 359 to 1 the plain way passes
				// through 180 and spins the character around its own axis.
				yaw = lerp_angle(e.yaw, other.yaw, factor)
				pitch = linalg.lerp(e.pitch, other.pitch, factor)
				// The pair is already here, and so is the tick gap between
				// them, so the velocity the wire does not carry costs one
				// subtraction. It is the average over at least a tick, which is
				// what a locomotion blend wants anyway.
				dt := f32(to.server_tick - from.server_tick) / game.TICK_RATE
				if dt > 0 do velocity = (other.position - e.position) / dt
			}
		}

		radius, height := entity_size(e)
		remote.drawn[remote.drawn_count] = {
			id        = id,
			team      = .Team_CT in e.flags ? .CT : .T,
			is_bot    = .Is_Bot in e.flags,
			crouching = .Crouching in e.flags,
			position  = position,
			height    = height,
			radius    = radius,
			yaw       = yaw,
			pitch     = pitch,
			weapon    = int(e.weapon),
			health    = e.health,
			velocity  = velocity,
		}
		remote.drawn_count += 1
	}
}

// How far back a hitch may reach for missed Fired flags. Replaying a burst of
// stale muzzle flashes after a stall reads as a glitch, not as catching up.
@(private = "file")
FIRE_SCAN_WINDOW :: 8

// The visible half of a remote shot -- streak and muzzle light -- cued by the
// Fired flag the server sets on the tick a pawn shot. The direction is the
// entity's quantized aim, not the server's actual pellet: a cue for where fire
// comes from, never a replay of what it hit.
@(private = "file")
scan_remote_fire :: proc() {
	t0 := u32(max(remote.render_tick, 0))

	start := remote.fire_scanned + 1
	if t0 > FIRE_SCAN_WINDOW && start < t0 - FIRE_SCAN_WINDOW {
		start = t0 - FIRE_SCAN_WINDOW
	}

	for tick := start; tick <= t0; tick += 1 {
		s := snapshot_at(tick)
		if s == nil do continue

		for id in 0 ..< game.MAX_PAWNS {
			if id not_in s.present || id == net_client.pawn_id do continue
			e := &s.entities[id]
			if .Fired not_in e.flags || .Alive not_in e.flags do continue

			weapon_index := int(e.weapon)
			if weapon_index >= game.WEAPON_COUNT do continue
			weapon := game.WEAPONS[weapon_index]
			// Bots shoot a hitscan stub while nominally holding the zero-value
			// knife, so their Fired is gunfire. A player's melee swing is not.
			if weapon.melee {
				if .Is_Bot not_in e.flags do continue
				weapon = game.WEAPONS[game.WEAPON_AK]
				weapon_index = game.WEAPON_AK
			}

			dir := game.view_forward(e.yaw, e.pitch)
			radius, height := entity_size(e)
			// Weapon height on the box model, pushed clear of its silhouette
			// so the streak starts outside the body.
			muzzle := e.position + {0, 0, height * 0.75} + dir * (radius + 0.15)

			end := muzzle + dir * weapon.range
			if hit, ok := physics.grid_raycast(&gs.grid, muzzle, dir, weapon.range); ok {
				end = hit.point
			}

			add_tracer(muzzle, end, weapon.tracer_speed)
			add_transient_light(muzzle, {1.0, 0.82, 0.5}, 26, 7, MUZZLE_FLASH_TIME)
			audio_emit({kind = .Fire, weapon = weapon_index, pos = muzzle})
		}
	}

	remote.fire_scanned = max(remote.fire_scanned, t0)
}

// Shortest way round between two angles in degrees. The wire quantizes yaw to
// a u16 over the full turn, so the wrap is not a corner case -- it is where
// every player standing near due west spends their time.
@(private = "file")
lerp_angle :: proc(a, b, t: f32) -> f32 {
	delta := b - a
	for delta > 180 do delta -= 360
	for delta < -180 do delta += 360
	return a + delta * t
}

// Hands every interpolated entity to the character renderer, posed and facing
// where it is looking.
submit_remote_entities :: proc() {
	for i in 0 ..< remote.drawn_count {
		d := &remote.drawn[i]
		submit_character(
			{
				id = d.id,
				position = d.position,
				yaw = d.yaw,
				pitch = d.pitch,
				velocity = d.velocity,
				height = d.height,
				team = d.team,
				weapon = d.weapon,
				crouching = d.crouching,
				health = d.health,
			},
		)
	}
}

// The boxes the cosmetic shot trace tests -- the same interpolated positions
// the player sees, so the marker agrees with the screen even before the
// server confirms the hit.
remote_target_box :: proc(d: ^Remote_Draw) -> physics.Aabb {
	return {
		min = d.position - {d.radius, d.radius, 0},
		max = d.position + {d.radius, d.radius, d.height},
	}
}

// Living enemies on screen right now, for the HUD's counter.
remote_enemies_alive :: proc() -> int {
	count := 0
	for i in 0 ..< remote.drawn_count {
		if remote.drawn[i].team != net_client.team do count += 1
	}
	return count
}
