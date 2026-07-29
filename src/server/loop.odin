package main

import "../game"
import "core:log"
import "core:time"

// The server's heartbeat: a fixed 64 Hz schedule against absolute deadlines,
// so the tick rate cannot drift no matter how long individual ticks take.
// Sleep gets the coarse part and a bounded spin the rest -- the OS timer is
// grainier than the margin a tick can afford.

// A stall (debugger, VM pause) re-anchors the schedule rather than replaying
// the backlog: the server catching up at full speed would fast-forward the
// match in front of everyone.
STALL_TICKS :: 8

SPIN_MARGIN :: time.Millisecond

run_loop :: proc() {
	period := time.Duration(f64(time.Second) / f64(game.TICK_RATE))
	start := time.tick_now()

	for sv.running {
		sv.tick += 1
		sv.gs.tick = u64(sv.tick)
		target := time.Duration(sv.tick) * period

		// 0. a pending SIGTERM/SIGINT, or a drain deadline running out
		shutdown_tick()

		// 1. everything the wire brought since the last tick, on both
		// transports, plus whatever Steam has to say about them
		receive_packets()
		steam_server_pump()
		steam_receive_packets()

		// 2. who is still here
		update_clients()

		// the anti-cheat layer: window bookkeeping, periodic verdict pass
		ac_tick()

		// 3. phase transitions, spawning, reliable events
		match_tick()

		// 4. the simulation proper
		sim_tick(game.TICK_DT)

		// 5. one snapshot per client
		send_snapshots()

		// the control plane: heartbeat to the master, drain requests back
		heartbeat_tick()

		free_all(context.temp_allocator)

		// 6. sleep out the rest of the tick
		elapsed := time.tick_since(start)
		if elapsed > target + STALL_TICKS * period {
			log.warnf(
				"Server: stalled {} ms, re-anchoring",
				time.duration_milliseconds(elapsed - target),
			)
			start = time.tick_now()
			start._nsec -= i64(target)
			continue
		}
		for {
			elapsed = time.tick_since(start)
			if elapsed >= target do break
			remaining := target - elapsed
			if remaining > SPIN_MARGIN {
				time.sleep(remaining - SPIN_MARGIN)
			}
		}
	}
}
