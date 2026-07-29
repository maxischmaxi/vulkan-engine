package main

import "../game"
import "../physics"
import "../protocol"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:time"

// The authoritative simulation step: consume one command per human, run the
// shared movement and fire control, tick the bots, keep the books. A human's
// fire resolves against hitboxes rewound to what its screen showed -- the
// history ring in game/lag_comp.odin.

// Muzzle cues for the snapshot: which pawns fired during this tick.
fired_this_tick: [game.MAX_PAWNS]bool

// Directional hit cues for the snapshot's datagram: what hit each pawn this
// tick. Cleared each sim_tick like fired_this_tick (both assume
// SNAPSHOT_DIVISOR == 1; a divisor > 1 must move the clear to the flush).
MAX_DAMAGE_EVENTS :: 8

Damage_Event :: struct {
	direction: f32, // world yaw degrees, victim toward attacker
	amount:    u8,
}

pending_damage: [game.MAX_PAWNS][MAX_DAMAGE_EVENTS]Damage_Event
pending_damage_count: [game.MAX_PAWNS]int

// Records a landed hit for the victim's next snapshot datagram. God-mode
// victims took nothing (damage_pawn no-ops), so they get no cue either.
queue_damage :: proc(attacker_position: [3]f32, victim: int, amount: int) {
	v := &sv.gs.pawns[victim]
	if v.god do return
	n := &pending_damage_count[victim]
	if n^ >= MAX_DAMAGE_EVENTS do return

	delta := [2]f32 {
		attacker_position.x - v.body.position.x,
		attacker_position.y - v.body.position.y,
	}
	direction := f32(0)
	if abs(delta.x) > 0.001 || abs(delta.y) > 0.001 {
		direction = math.to_degrees(math.atan2(delta.y, delta.x))
	}
	pending_damage[victim][n^] = {
		direction = direction,
		amount    = u8(clamp(amount, 0, 255)),
	}
	n^ += 1
}

history: game.Lag_History

// Visible in the health line: how many shots got the rewind vs. fell back to
// current positions, and how far back they went.
Lag_Stats :: struct {
	fires:   int,
	rewound: int,
	age_sum: int, // in ticks, over rewound fires
}

lag_stats: Lag_Stats

// Where the shooter's screen was: the snapshot its command was built against,
// minus the interpolation delay. Zero-trust -- the base is clamped at store
// time and the result is clamped into the recent past here.
@(private = "file")
rewind_target :: proc(base: u32) -> (u32, bool) {
	if base <= protocol.INTERP_TICKS || sv.tick <= 1 do return 0, false
	t := base - u32(protocol.INTERP_TICKS)
	lo := u32(1)
	if sv.tick > game.MAX_REWIND_TICKS do lo = sv.tick - game.MAX_REWIND_TICKS
	return clamp(t, lo, sv.tick - 1), true
}

// A phase change takes a round trip to reach the client, so commands built
// under the old phase keep arriving for a moment afterwards. Half a second of
// slack, well past any playable ping, keeps an honest client out of the count.
FIRE_DENY_GRACE_TICKS :: 32

// Anti-cheat groundwork rather than anti-cheat: the trigger is already refused
// by the time this runs, and all this does is notice who kept pulling it.
//
// Only the phase is counted. Death travels to the client the same way, but
// orders of magnitude more often, so counting it would bury the one signal
// that means something under the noise of ordinary dying.
@(private = "file")
note_fire_block :: proc(slot: ^Client_Slot, ev: game.Fire_Events) {
	if ev.blocked != .Not_In_Match do return
	if sv.tick - match.phase_start_tick < FIRE_DENY_GRACE_TICKS do return

	slot.fire_denied += 1
	if !slot.fire_denied_logged {
		slot.fire_denied_logged = true
		log.warnf("Server: client {} pulled the trigger in {}", slot.pawn_id, match.phase)
	}
}

sim_tick :: proc(dt: f32) {
	for &f in fired_this_tick do f = false
	for &n in pending_damage_count do n = 0

	for &slot in clients {
		if slot.state != .In_Game do continue
		p := &sv.gs.pawns[slot.pawn_id]
		if !p.active do continue

		cmd, base := consume_command(&slot)
		p.prev_position = p.body.position

		// Before any branch: the telemetry's turn stream must see every
		// command, or death and countdown would tear holes into it.
		telemetry_note_angles(&slot.aim, cmd)

		// The head turns in every phase and in every state: looking around is
		// not an act of play. pawn_move writes these same two fields on the
		// live path below, so doing it here costs the live path nothing.
		p.yaw = cmd.yaw
		p.pitch = cmd.pitch

		if !p.alive {
			p.respawn_in -= dt
			if p.respawn_in <= 0 && match.phase == .Live {
				respawn_human(&slot)
				continue
			}
			// A corpse still holsters for the next life and its timers still
			// run down; fire control refuses the trigger on its own.
			note_fire_block(
				&slot,
				game.tick_pawn_weapon(&sv.gs, slot.pawn_id, cmd, dt, match.phase),
			)
			continue
		}

		if match.phase != .Live {
			// Countdown and Post: the feet are frozen, the holster is not.
			// Nothing here can fire, so the rewind is skipped outright.
			note_fire_block(
				&slot,
				game.tick_pawn_weapon(&sv.gs, slot.pawn_id, cmd, dt, match.phase),
			)
			continue
		}

		game.pawn_move(&sv.gs, p, cmd, dt)

		// Wrap every tick, not just firing ones -- whether the trigger lands
		// is unknowable before the fire control ran, and moving 16 records
		// back and forth is trivial.
		rewind_tick, want := rewind_target(base)
		rw: game.Rewind
		rewound := false
		if want {
			rw, rewound = game.lag_comp_begin(&history, &sv.gs, rewind_tick, slot.pawn_id)
		}
		ev := game.tick_pawn_weapon(&sv.gs, slot.pawn_id, cmd, dt, match.phase)
		if rewound do game.lag_comp_end(&sv.gs, &rw)

		// Beside note_fire_block in spirit: collected, never judged here.
		telemetry_note_fire(&slot.aim, cmd, ev)

		for v in ev.victims[:ev.victim_count] {
			// One cue per victim per blast, however many pellets landed: the
			// summed nominal damage, pre-armor -- a cosmetic intensity, not
			// the bookkept loss.
			queue_damage(p.body.position, v.pawn, v.nominal)
		}
		if ev.fired {
			fired_this_tick[slot.pawn_id] = true
			lag_stats.fires += 1
			if rewound {
				lag_stats.rewound += 1
				lag_stats.age_sum += int(sv.tick - rewind_tick)
			}
		}
		for v in ev.victims[:ev.victim_count] {
			if v.killed do on_pawn_killed(slot.pawn_id, v.pawn)
		}

		// A fall through the world is a death, not an exploit.
		if p.body.position.z < -50 {
			game.kill_pawn(p)
			on_pawn_killed(-1, slot.pawn_id)
		}
	}

	if match.phase == .Live {
		tick_server_bots(dt)
	}

	// After everything moved: history[N] must equal what snapshot N tells the
	// clients -- the agreement the rewind rests on.
	game.lag_history_record(&history, &sv.gs, sv.tick)
}

// Where a fresh life begins: the team's own corner for the first spawn of a
// match, a random room after that -- TDM respawns spreading out is what keeps
// a 60-second match moving.
spawn_human :: proc(slot: ^Client_Slot) {
	p := &sv.gs.pawns[slot.pawn_id]

	position := team_spawn_position(slot.team)
	game.init_pawn(p, position, team_spawn_yaw(slot.team))
	p.team = slot.team
	p.god = slot.debug_god
	p.infinite_ammo = slot.debug_infinite
	apply_loadout_to_pawn(p, slot.loadout)
	log.infof(
		"Server: spawned client {} on {} at {} holding {} (armor {})",
		client_index(slot),
		slot.team,
		position,
		game.WEAPONS[p.weapon.index].name,
		p.armor,
	)
}

// A dev affordance, applied loudly: every grant is one log line. A hardened
// server never gets here -- the Debug_Flags tripwire in handle_packet bans
// the sender instead (anticheat.odin).
apply_debug_flags :: proc(slot: ^Client_Slot, flags: protocol.Debug_Flags) {
	slot.debug_god = flags.god
	slot.debug_infinite = flags.infinite_ammo

	p := &sv.gs.pawns[slot.pawn_id]
	if p.active {
		p.god = flags.god
		p.infinite_ammo = flags.infinite_ammo
		// Toggling infinite on with a run-dry magazine would still show zero;
		// topping up makes the toggle mean what it says.
		if flags.infinite_ammo do game.refill_pawn_ammo(&p.weapon)
	}
	log.warnf(
		"Server: client {} debug flags -- god {}, infinite ammo {}",
		client_index(slot),
		flags.god,
		flags.infinite_ammo,
	)
}

// T faces north up mid, CT faces south back down it -- each toward the map,
// never into their own back wall.
@(private = "file")
team_spawn_yaw :: proc(team: game.Team) -> f32 {
	return team == .T ? game.SPAWN_YAW : -game.SPAWN_YAW
}

respawn_human :: proc(slot: ^Client_Slot) {
	p := &sv.gs.pawns[slot.pawn_id]

	probe := physics.Body {
		radius = game.PLAYER_RADIUS,
		height = game.PLAYER_HEIGHT,
	}
	position, ok := server_find_spawn(probe)
	if !ok {
		position = team_spawn_position(slot.team)
	}
	game.init_pawn(p, position, team_spawn_yaw(slot.team))
	p.team = slot.team
	p.god = slot.debug_god
	p.infinite_ammo = slot.debug_infinite
	apply_loadout_to_pawn(p, slot.loadout)
}

// T starts in T-spawn, CT in CT-spawn -- the two rooms the map already names.
@(private = "file")
team_spawn_position :: proc(team: game.Team) -> [3]f32 {
	if team == .T do return game.SPAWN_POSITION

	area := game.MAP_SPAWN_AREAS[8] // CT spawn
	x := (area.min.x + area.max.x) * 0.5
	y := (area.min.y + area.max.y) * 0.5
	z, found := physics.grid_ground_below(&sv.gs.grid, {x, y, area.floor + 2}, 5)
	if !found do z = area.floor
	return {x, y, z + 0.25}
}

// The spawn probe every respawn uses: a random room, a random point in it,
// the ground under that point, and a fit check. Mirrors the client's local
// version; both will collapse into one once the client sheds its local bots.
server_find_spawn :: proc(probe: physics.Body) -> ([3]f32, bool) {
	for attempt in 0 ..< 64 {
		area := game.MAP_SPAWN_AREAS[rand.int_max(len(game.MAP_SPAWN_AREAS), sv.gs.rng)]

		x := (area.min.x + area.max.x) * 0.5
		y := (area.min.y + area.max.y) * 0.5
		if attempt < 48 {
			x = rand.float32_range(area.min.x, area.max.x, sv.gs.rng)
			y = rand.float32_range(area.min.y, area.max.y, sv.gs.rng)
		}

		z, found := physics.grid_ground_below(&sv.gs.grid, {x, y, area.floor + 2}, 5)
		if !found do continue

		candidate := [3]f32{x, y, z + 0.01}
		if physics.grid_overlaps_any(&sv.gs.grid, physics.body_aabb_at(probe, candidate)) {
			continue
		}
		return candidate, true
	}
	return {}, false
}

// One snapshot per client per tick: the shared entity block, then the private
// block only its owner may see.
send_snapshots :: proc() {
	if protocol.SNAPSHOT_DIVISOR > 1 && sv.tick % protocol.SNAPSHOT_DIVISOR != 0 do return

	snap: protocol.Snapshot
	snap.server_tick = sv.tick
	snap.baseline_tick = 0 // per-client baselines are chosen below
	snap.phase = match.phase
	snap.time_left = match_time_left()
	snap.t_score = u8(clamp(match.t_score, 0, 255))
	snap.ct_score = u8(clamp(match.ct_score, 0, 255))

	for &p, i in sv.gs.pawns {
		if !p.active do continue
		snap.present += {i}
		e := &snap.entities[i]

		e.flags = {}
		if p.alive do e.flags += {.Alive}
		if p.crouching do e.flags += {.Crouching}
		if p.body.on_ground do e.flags += {.On_Ground}
		if p.is_bot do e.flags += {.Is_Bot}
		if p.team == .CT do e.flags += {.Team_CT}
		if fired_this_tick[i] do e.flags += {.Fired}
		e.position = p.body.position
		e.yaw = p.yaw
		e.pitch = p.pitch
		e.health = u8(clamp(p.health, 0, 255))
		e.weapon = u8(p.weapon.index)
	}

	snap_history_store(&snap, sv.tick)

	zero_base: protocol.Snapshot

	for &slot in clients {
		if slot.state == .Empty || slot.state == .Authenticating do continue

		s := snap
		s.last_input_tick = slot.consumed_tick

		// Delta against what the client confirms holding; anything else --
		// fresh join, stale ack, fabricated tick -- degrades to a full
		// snapshot, never to a guess.
		base := snap_history_at(slot.acked_snapshot)
		if base == nil {
			base = &zero_base
		} else {
			s.baseline_tick = slot.acked_snapshot
		}

		if slot.state == .In_Game {
			p := &sv.gs.pawns[slot.pawn_id]
			if p.active {
				s.has_private = true
				s.private = {
					velocity       = p.body.velocity,
					armor          = u8(clamp(p.armor, 0, 255)),
					ammo_mag       = u8(clamp(p.weapon.ammo[p.weapon.index].mag, 0, 255)),
					ammo_reserve   = u8(clamp(p.weapon.ammo[p.weapon.index].reserve, 0, 255)),
					cooldown_ticks = u8(clamp(int(p.weapon.cooldown * game.TICK_RATE), 0, 255)),
					reload_ticks   = u8(clamp(int(p.weapon.reload_left * game.TICK_RATE), 0, 255)),
					kills          = u8(clamp(p.kills, 0, 255)),
					deaths         = u8(clamp(p.deaths, 0, 255)),
					spray_progress = u8(clamp(int(p.weapon.spray.progress * 8), 0, 255)),
					spray_seed     = p.weapon.spray.seed,
				}
			}
		}

		buf: [protocol.MTU]u8
		w := protocol.writer(buf[:])
		protocol.connection_begin_packet(&slot.conn, &w)
		// Damage cues first: the client must register the heading before the
		// snapshot's health drop is reconciled -- see reconcile in predict.odin.
		if slot.state == .In_Game {
			for e in pending_damage[slot.pawn_id][:pending_damage_count[slot.pawn_id]] {
				protocol.write_u8(&w, u8(protocol.Msg_Id.Damage))
				protocol.write_damage(
					&w,
					{tick = sv.tick, direction = e.direction, amount = e.amount},
				)
			}
		}
		protocol.write_u8(&w, u8(protocol.Msg_Id.Snapshot))
		protocol.write_snapshot(&w, s, base)
		if w.overflow {
			log.warnf("Server: snapshot overflowed the MTU, not sent")
			continue
		}
		send_to(slot.peer, w.buf[:w.off])
	}

	log_server_stats()
}

// One line every few seconds, so the server's health is visible in a terminal
// without a debugger.
@(private = "file")
log_server_stats :: proc() {
	@(static) last: time.Tick
	if time.duration_seconds(time.tick_since(last)) < 5 do return
	last = time.tick_now()

	connected := 0
	denied := 0
	for &slot in clients {
		if slot.state != .Empty do connected += 1
		denied += slot.fire_denied
	}
	if connected == 0 && match.phase == .Idle do return

	avg_age := f32(0)
	if lag_stats.rewound > 0 {
		avg_age = f32(lag_stats.age_sum) / f32(lag_stats.rewound)
	}
	log.infof(
		"Server: tick {}  phase {}  T {} : {} CT  {} client(s)  {:.0f}s left  lagcomp {}/{} avg {:.1f}t",
		sv.tick,
		match.phase,
		match.t_score,
		match.ct_score,
		connected,
		match_time_left(),
		lag_stats.rewound,
		lag_stats.fires,
		avg_age,
	)
	// Only when there is something to say: on a clean server this line never
	// appears, which is what makes it worth reading when it does.
	if denied > 0 {
		log.warnf("Server: {} trigger pull(s) refused outside a live match", denied)
	}
	log_aim_stats()
}
