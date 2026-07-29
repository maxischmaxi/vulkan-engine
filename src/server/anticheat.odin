package main

import ac_core "../anticheat"
import "core:log"
import "core:time"

// The anti-cheat layer's server end: one sink every detector reports to, one
// periodic pass over the telemetry the simulation already collects. Detection
// lives wherever the data already is (clients.odin, aim_telemetry.odin); the
// verdict and the enforcement live here. There is no second chance by design:
// a violation is a permanent ban and an immediate kick.

// The statistical pass runs every 5 s at 64 Hz, beside the existing stats
// cadence; the packet-rate window resets every second.
AC_SCAN_TICKS :: 320
AC_WINDOW_TICKS :: 64

// Datagrams per peer per second. An honest client sends one per client tick
// plus handshake stragglers; four times that only happens when a stalled
// route flushes at once, which is why one hot window is shed, not banned.
AC_PACKET_BUDGET :: 256

// Consecutive saturated windows before the flood is a violation. A route
// flush empties in one window; sustaining the budget for this long means the
// peer really sends at that rate, and the connection timeout (5 s) proves the
// windows were genuinely consecutive.
AC_FLOOD_WINDOWS :: 3

// O(1) per-event counters, embedded in Client_Slot beside Aim_Telemetry.
// Incremented where the events happen, judged only by the periodic pass.
Anomaly_Counters :: struct {
	packets_window: int, // datagrams since the last one-second window reset
	flood_windows:  int, // consecutive windows over the packet budget
	future_inputs:  int, // store_input refusals: newest_tick too far ahead
	backlog_trims:  int, // consume_command had to jump a grown backlog
}

Anticheat :: struct {
	// -ac-shadow: statistical verdicts log "would ban" instead of banning.
	// Hard violations ban regardless -- they are protocol impossibilities.
	shadow: bool,
	// -harden (dev builds): run the release-grade refusal paths without a
	// STEAM_REQUIRED build, so the tripwire is testable headless.
	harden: bool,
}

ac: Anticheat

// Hardened = this server refuses dev affordances and bans their senders.
ac_hardened :: proc() -> bool {
	when STEAM_REQUIRED {
		return true
	} else {
		return ac.harden
	}
}

// The one sink. Returns whether the slot was dropped; after true the caller
// must not touch the slot again -- handle_packet returns out of its message
// loop immediately, the scan loop moves to the next slot.
ac_flag :: proc(slot: ^Client_Slot, v: ac_core.Violation) -> bool {
	if !ac_core.violation_hard(v) && ac.shadow {
		log.warnf(
			"AC: client {} ({}) would ban for {} (shadow)",
			client_index(slot),
			peer_desc(slot.peer),
			v,
		)
		return false
	}
	log.warnf("AC: client {} ({}) banned for {}", client_index(slot), peer_desc(slot.peer), v)
	ban_add(ban_entry_for(slot, v))
	kick_client(slot, .Banned)
	return true
}

// Ban an identity that owns no slot (connect-time refusals, e.g. an account
// borrowing a banned owner's library).
ac_ban_account :: proc(steam_id, owner_id: u64, v: ac_core.Violation) {
	log.warnf("AC: account {} (owner {}) banned for {}", steam_id, owner_id, v)
	ban_add(ac_core.Ban_Line{steam_id = steam_id, owner_id = owner_id, reason = v, stamp = ban_stamp()})
}

@(private = "file")
ban_entry_for :: proc(slot: ^Client_Slot, v: ac_core.Violation) -> ac_core.Ban_Line {
	entry := ac_core.Ban_Line {
		reason = v,
		stamp  = ban_stamp(),
	}
	switch slot.peer.kind {
	case .Steam:
		entry.steam_id = slot.peer.steam_id
		if slot.owner_steam_id != slot.peer.steam_id {
			entry.owner_id = slot.owner_steam_id
		}
	case .Udp:
		entry.ip = ban_ip_key(slot.peer.ep)
	}
	return entry
}

@(private = "file")
ban_stamp :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// One call per server tick from run_loop: window bookkeeping every second,
// the statistical pass every AC_SCAN_TICKS. Costs nothing in between.
ac_tick :: proc() {
	if sv.tick % AC_WINDOW_TICKS == 0 {
		for &slot in clients {
			if slot.state == .Empty do continue
			if slot.anomaly.packets_window > AC_PACKET_BUDGET {
				slot.anomaly.flood_windows += 1
				if slot.anomaly.flood_windows >= AC_FLOOD_WINDOWS {
					if ac_flag(&slot, .Packet_Flood) do continue
				}
			} else {
				slot.anomaly.flood_windows = 0
			}
			slot.anomaly.packets_window = 0
		}
	}

	if sv.tick % AC_SCAN_TICKS != 0 do return
	for &slot in clients {
		if slot.state != .In_Game do continue
		v := ac_core.evaluate(ac_stats_for(&slot))
		if v == .None do continue
		ac_flag(&slot, v)
	}
}

@(private = "file")
ac_stats_for :: proc(slot: ^Client_Slot) -> ac_core.Aim_Stats {
	aim := &slot.aim
	return {
		fired = aim.fired,
		hits = aim.hits,
		snap_count = aim.snap_count,
		comp_shots = aim.comp_shots,
		comp_r = telemetry_comp_r(aim),
		perfect_shots = aim.perfect_shots,
		norecoil_hits = aim.norecoil_hits,
		fire_denied = slot.fire_denied,
		future_inputs = slot.anomaly.future_inputs,
		backlog_trims = slot.anomaly.backlog_trims,
	}
}
