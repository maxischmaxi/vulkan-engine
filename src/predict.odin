package main

import "core:log"
import "game"
import "protocol"

// Client-side prediction: the own pawn runs the shared movement immediately,
// every command is remembered, and each snapshot is checked against what was
// predicted for it. On divergence the pawn snaps to the server's state and the
// pending commands replay on top -- the standard loop every serious shooter
// runs, made cheap here because the whole move step is pure and shared.

PENDING_CAP :: 128

// Below this the server and the prediction are considered in agreement; f32
// noise lives well under it, real mispredictions well over.
RECONCILE_EPSILON :: 0.02

// The spray mirror only adopts the server's burst depth after this long
// without a local shot -- past any honest RTT plus a snapshot interval, so a
// stale snapshot can never re-arm a burst the client already cooled off.
SPRAY_ADOPT_IDLE :: 0.5

// The ammo mirror adopts the server's count only after this long without a
// local shot: a snapshot from RTT ago saying "one round left" must not hand a
// held trigger a phantom shot the server will refuse.
AMMO_ADOPT_QUIET :: 0.35

Pending_Input :: struct {
	tick:          u32,
	cmd:           game.Pawn_Input,
	predicted_pos: [3]f32, // position AFTER simulating cmd
}

Predictor :: struct {
	pending:    [PENDING_CAP]Pending_Input,
	input_tick: u32, // the tick number the NEXT command will carry
	unsent:     int,
}

predictor: Predictor

// One predicted tick of the own pawn -- the networked replacement for
// tick_player. Movement only runs in phases where the server would run it
// too, or the two simulations would disagree by construction.
predict_tick :: proc(dt: f32) {
	player.prev_position = player.body.position
	decay_player_fx(dt)

	cmd := build_local_input()
	// Predict with the exact angles the server will decode off the wire.
	cmd.yaw, cmd.pitch = protocol.wire_angles(cmd.yaw, cmd.pitch)

	if game.phase_is_action(net_client.phase) && player.alive {
		ev := game.pawn_move(&gs, player, cmd, dt)
		if ev.jumped {
			audio_emit({kind = .Jump, local = true})
		}
		if ev.landed {
			view_note_landing(ev.impact)
			if ev.impact >= LAND_MIN_IMPACT {
				audio_emit({kind = .Land, local = true, intensity = min(ev.impact / LAND_SPEED_FULL, 1)})
			}
		}
	} else {
		// The server mirrors the head even while the feet are frozen.
		player.yaw = cmd.yaw
		player.pitch = cmd.pitch
		if !player.alive {
			// cosmetic countdown for the death overlay; the server owns the
			// actual respawn and will say so in a snapshot
			player.respawn_in = max(player.respawn_in - dt, 0)
		}
	}

	slot := &predictor.pending[predictor.input_tick % PENDING_CAP]
	slot.tick = predictor.input_tick
	slot.cmd = cmd
	slot.predicted_pos = player.body.position

	predictor.input_tick += 1
	predictor.unsent += 1
}

// One datagram per frame with the newest commands, oldest first. Redundancy
// means the server survives lost packets without asking.
send_pending_inputs :: proc() {
	if !net_client.joined do return
	if predictor.unsent == 0 do return
	predictor.unsent = 0

	newest := predictor.input_tick - 1
	count := u8(min(protocol.INPUT_REDUNDANCY, int(newest) + 1))

	msg: protocol.Input_Msg
	msg.last_snapshot_tick = net_client.latest_tick
	msg.newest_tick = newest
	msg.count = count
	for i in 0 ..< int(count) {
		tick := newest - u32(int(count) - 1 - i)
		slot := &predictor.pending[tick % PENDING_CAP]
		if slot.tick == tick {
			msg.commands[i] = slot.cmd
		}
	}

	buf: [protocol.MTU]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&net_client.conn, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Input))
	protocol.write_input(&w, msg)
	net_send(w.buf[:w.off])
}

// Folds a snapshot into the predicted state: adopt what only the server may
// decide, check the position against what was predicted for the acked
// command, and replay the outstanding commands if it disagrees.
reconcile :: proc(s: ^protocol.Snapshot) {
	// the own entity, if the server placed us in this snapshot
	if net_client.pawn_id not_in s.present do return
	own := &s.entities[net_client.pawn_id]

	was_alive := player.alive
	old_health := player.health

	// server-owned facts
	player.active = true
	player.team = net_client.team
	player.health = int(own.health)
	player.alive = .Alive in own.flags

	if s.has_private {
		p := s.private
		player.armor = int(p.armor)
		// What the pawn wears, which is not what the buy menu has pending: a
		// buy delivered on respawn only reaches the HUD once it is worn.
		player.loadout.helmet = .Helmet in p.gear
		player.loadout.defuse_kit = .Defuse_Kit in p.gear
		// kill confirmation: the red marker arrives with the server's word.
		// The first private block only seeds the counter, so a rejoin cannot
		// flash a marker for kills from another life.
		if net_client.kills_synced && p.kills > net_client.kills_seen {
			weapon_state.hit_marker = HIT_MARKER_TIME
			weapon_state.hit_killed = true
		}
		net_client.kills_seen = p.kills
		net_client.kills_synced = true
		player.kills = int(p.kills)
		player.deaths = int(p.deaths)
		// The belt is the server's word without qualification: nothing local
		// spends a grenade, the throw does, and that happens over there. The
		// count therefore drops one round trip after the throw, which nobody can
		// see -- unlike the hand below, which has to move on the frame it is
		// asked for.
		for kind in game.Grenade_Kind do player.grenades[kind] = p.grenades[int(kind)]
		adopt_server_hand(p.hand)
		// The cosmetic ammo counter re-syncs to the authoritative one, but only
		// while the local weapon is quiet and matches the server's hand --
		// mid-burst the local count is fresher than the snapshot's. Reload and
		// respawn refills still land: both imply a quiet trigger.
		if weapon_state.index == int(own.weapon) &&
		   weapon_state.cooldown <= 0 &&
		   weapon_state.spray.cool > AMMO_ADOPT_QUIET {
			weapon_ammo[weapon_state.index].mag = int(p.ammo_mag)
			weapon_ammo[weapon_state.index].reserve = int(p.ammo_reserve)
		}
		// The spray mirror: the seed is the server's word even mid-burst (the
		// deterministic prefix masked the swap window), but the depth is only
		// adopted when locally long idle -- mid-burst the local track is ~RTT
		// fresher, and a stale snapshot must never re-arm a burst the client
		// already cooled off.
		if weapon_state.index == int(own.weapon) {
			if weapon_state.spray.progress > 0 &&
			   p.spray_progress > 0 &&
			   p.spray_seed != weapon_state.spray.seed {
				weapon_state.spray.seed = p.spray_seed
				game.spray_build_points(
					current_weapon().spray,
					p.spray_seed,
					&weapon_state.spray.points,
				)
			}
			if weapon_state.spray.progress == 0 &&
			   weapon_state.spray.cool > SPRAY_ADOPT_IDLE {
				weapon_state.spray.progress = f32(p.spray_progress) / 8
				weapon_state.spray.seed = p.spray_seed
				game.spray_build_points(
					current_weapon().spray,
					p.spray_seed,
					&weapon_state.spray.points,
				)
			}
		}
	}

	// life edges
	if was_alive && !player.alive {
		player.respawn_in = PLAYER_RESPAWN_DELAY
		player.body.velocity = {}
		reset_zoom() // dead eyes do not stay scoped
		log.infof("NET: died ({} deaths)", player.deaths)
	}
	if !was_alive && player.alive {
		// a respawn is a teleport, not a movement
		player.body.position = own.position
		player.prev_position = own.position
		player.body.velocity = s.has_private ? s.private.velocity : {}
		player.crouching = false
		player_fx = {} // no indicator carried over from the last life
		init_view()
		// The buy menu's pending loadout is confirmed by now -- the reliable
		// channel delivered it before the server could spawn us -- and the
		// weapon in hand is the server's word, not a local guess.
		player.loadout = buy_menu.pending
		refill_all_ammo()
		select_weapon(int(own.weapon))
		log.infof("NET: respawned holding {} (armor {})", current_weapon().name, player.armor)
	}
	if player.health < old_health && player.alive {
		// The Damage message carries the heading and rides the same datagram
		// as this snapshot, written before it -- so if it arrived, the tick
		// below is already newer. The health drop is only the lost-datagram
		// fallback.
		if net_client.last_damage_tick <= net_client.last_health_tick {
			register_hit({}, old_health - player.health)
		}
	}
	net_client.last_health_tick = s.server_tick

	if !player.alive do return

	// position agreement against the acked command
	acked := s.last_input_tick
	slot := &predictor.pending[acked % PENDING_CAP]
	if slot.tick != acked || acked >= predictor.input_tick {
		// Nothing predicted for that tick (fresh join, long stall): adopt the
		// server position outright rather than guessing.
		player.body.position = own.position
		player.prev_position = own.position
		if s.has_private do player.body.velocity = s.private.velocity
		return
	}

	diff := own.position - slot.predicted_pos
	err := abs(diff.x) + abs(diff.y) + abs(diff.z)
	if err <= RECONCILE_EPSILON do return

	// misprediction: snap to the server and replay what it has not seen yet
	net_client.corrections += 1
	player.body.position = own.position
	if s.has_private do player.body.velocity = s.private.velocity
	player.body.on_ground = .On_Ground in own.flags

	for tick := acked + 1; tick < predictor.input_tick; tick += 1 {
		p := &predictor.pending[tick % PENDING_CAP]
		if p.tick != tick do break
		if game.phase_is_action(net_client.phase) {
			game.pawn_move(&gs, player, p.cmd, game.TICK_DT)
		}
		p.predicted_pos = player.body.position
	}

	// A correction that moved the feet by more than a stair is a teleport the
	// prediction missed -- a round reset moving survivors across the map. Not
	// a movement, so the eye must not slide through it.
	if abs(diff.z) > game.STEP_HEIGHT do view_reset_feet()

	// prev_position is left alone: the frame lerps from the old visual
	// position into the corrected one over a single tick, which hides the snap
}
