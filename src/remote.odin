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
}

Remote_View :: struct {
	render_tick: f64, // drift-corrected interpolation clock, in server ticks
	initialized: bool,
	drawn:       [game.MAX_PAWNS]Remote_Draw, // rebuilt every frame
	drawn_count: int,
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
	}

	remote.render_tick += f64(frame_dt) * game.TICK_RATE
	if abs(remote.render_tick - target) > 4 {
		remote.render_tick = target
	} else {
		remote.render_tick += (target - remote.render_tick) * 0.1
	}

	interpolate_remotes()
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
		if to != nil && id in to.present {
			other := &to.entities[id]
			if .Alive in other.flags {
				position = linalg.lerp(e.position, other.position, factor)
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
		}
		remote.drawn_count += 1
	}
}

// Hands every interpolated entity to the prop renderer, in its team's colour.
submit_remote_entities :: proc() {
	for i in 0 ..< remote.drawn_count {
		d := &remote.drawn[i]
		center := d.position + [3]f32{0, 0, d.height * 0.5}
		size := [3]f32{d.radius * 2, d.radius * 2, d.height}
		add_world_prop(prop_transform(center, size), TEAM_COLORS[d.team], roughness = 0.7)
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
