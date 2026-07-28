package main

import "../game"
import "core:log"
import "core:math"

// Aim telemetry: the server watching the input stream it already owns. Every
// number here is computed from wire-quantized angles and the server's own
// fire events -- no client claim enters. Version one only collects and logs;
// the accumulators are the stable interface the future anti-cheat detector
// consumes, and drawing conclusions is deliberately left to it.
//
// The signals, and the cheats they shadow:
//  - snap_count / max_fire_step: aim that teleports onto a target between two
//    64 Hz commands and fires (aimbot flicks).
//  - comp_* sums: correlation between the player's pull and the inverse spray
//    pattern; a recoil script tracks it near-perfectly, a human does not
//    (r = comp_dot / sqrt(comp_pattern_sq * comp_player_sq)).
//  - perfect_shots: pulls that mirror the pattern to within quantizer noise.
//  - norecoil_hits: pawn hits while the pattern demanded degrees of pull and
//    the player pulled essentially none -- honestly impossible, and a modified
//    client that removed the pattern produces exactly this.

AIM_SNAP_DEG :: 20.0 // one-tick step on a firing tick; humans rarely, bots constantly
AIM_PERFECT_EPS :: 0.012 // about two yaw-quantizer steps (bytes.odin)
AIM_NORECOIL_COMP :: 0.5 // "did not pull at all", degrees
AIM_NORECOIL_PATTERN :: 2.0 // while the pattern demanded at least this much
AIM_COMP_MIN_PATTERN :: 0.25 // correlation only counts shots with real deviation

Aim_Telemetry :: struct {
	// the turn stream, command to command
	last_yaw, last_pitch: f32,
	have_last:            bool,
	last_step:            f32, // degrees between the last two commands
	// flick signal, on firing ticks only
	max_fire_step:        f32,
	snap_count:           int,
	// where the current burst started; compensation is measured against it
	spray_start_yaw:      f32,
	spray_start_pitch:    f32,
	// accumulators for the future detector
	comp_dot:             f64,
	comp_pattern_sq:      f64,
	comp_player_sq:       f64,
	comp_shots:           int,
	perfect_shots:        int,
	norecoil_hits:        int,
	fired:                int,
	hits:                 int, // trigger pulls that connected with a pawn
	logged_fired:         int, // stats-line bookkeeping, not a signal
}

@(private = "file")
wrap_degrees :: proc(d: f32) -> f32 {
	w := math.mod(d, 360)
	if w >= 180 do w -= 360
	if w < -180 do w += 360
	return w
}

// Every consumed command, before any alive/phase branch: the turn stream must
// have no gaps, or a respawn's legitimate flick would read as a snap.
telemetry_note_angles :: proc(aim: ^Aim_Telemetry, cmd: game.Pawn_Input) {
	if aim.have_last {
		dy := wrap_degrees(cmd.yaw - aim.last_yaw)
		dp := cmd.pitch - aim.last_pitch
		aim.last_step = math.sqrt(dy * dy + dp * dp)
	}
	aim.last_yaw = cmd.yaw
	aim.last_pitch = cmd.pitch
	aim.have_last = true
}

// After the live-path fire control ran. The fire event carries the seeded
// pattern offset the pull actually flew with -- an index alone could not
// recompute it.
telemetry_note_fire :: proc(aim: ^Aim_Telemetry, cmd: game.Pawn_Input, ev: game.Fire_Events) {
	if !ev.fired do return
	aim.fired += 1
	if ev.victim_count > 0 do aim.hits += 1

	if aim.have_last {
		aim.max_fire_step = max(aim.max_fire_step, aim.last_step)
		if aim.last_step > AIM_SNAP_DEG do aim.snap_count += 1
	}

	if ev.spray_progress <= 0 {
		aim.spray_start_yaw = cmd.yaw
		aim.spray_start_pitch = cmd.pitch
		return
	}

	pattern := ev.spray_offset
	plen := math.sqrt(pattern.x * pattern.x + pattern.y * pattern.y)
	if plen < AIM_COMP_MIN_PATTERN do return

	comp := [2]f32 {
		wrap_degrees(cmd.yaw - aim.spray_start_yaw),
		cmd.pitch - aim.spray_start_pitch,
	}
	clen := math.sqrt(comp.x * comp.x + comp.y * comp.y)

	aim.comp_dot += f64(comp.x) * f64(-pattern.x) + f64(comp.y) * f64(-pattern.y)
	aim.comp_pattern_sq += f64(plen) * f64(plen)
	aim.comp_player_sq += f64(clen) * f64(clen)
	aim.comp_shots += 1

	miss := [2]f32{comp.x + pattern.x, comp.y + pattern.y}
	if plen > 1 && math.sqrt(miss.x * miss.x + miss.y * miss.y) < AIM_PERFECT_EPS {
		aim.perfect_shots += 1
	}
	if plen > AIM_NORECOIL_PATTERN && clen < AIM_NORECOIL_COMP && ev.victim_count > 0 {
		aim.norecoil_hits += 1
	}
}

// The compensation correlation so far: 1 = every pull the exact inverse of
// the pattern, 0 = unrelated, negative = pulling with the recoil.
telemetry_comp_r :: proc(aim: ^Aim_Telemetry) -> f64 {
	denom := math.sqrt(aim.comp_pattern_sq * aim.comp_player_sq)
	if denom <= 0 do return 0
	return aim.comp_dot / denom
}

// One line per client beside the server's health line, only when new trigger
// pulls arrived since the last one.
log_aim_stats :: proc() {
	for &slot in clients {
		if slot.state != .In_Game do continue
		aim := &slot.aim
		if aim.fired <= aim.logged_fired do continue
		aim.logged_fired = aim.fired
		log.infof(
			"Server: aim client {}: {} fired {} hit, max step {:.1f}, {} snaps, comp r {:.3f} over {}, {} perfect, {} norecoil-hits",
			slot.pawn_id,
			aim.fired,
			aim.hits,
			aim.max_fire_step,
			aim.snap_count,
			telemetry_comp_r(aim),
			aim.comp_shots,
			aim.perfect_shots,
			aim.norecoil_hits,
		)
	}
}
