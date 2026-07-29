package main

import "../mm"
import "core:time"

// The agent's heartbeat: region, capacity, occupancy, every 2 seconds --
// immediately when the occupancy changed, so the master's capacity math never
// runs on stale numbers longer than a loop turn.

agent_heartbeat :: proc(force: bool) {
	if !force && time.duration_seconds(time.tick_since(ag.last_hb)) < mm.HEARTBEAT_SECONDS {
		return
	}
	ag.last_hb = time.tick_now()

	buf: [mm.MM_MAX_DATAGRAM]u8
	w := mm.writer(buf[:])
	mm.frame_begin(&w, .Agent_Heartbeat)
	mm.write_agent_heartbeat(
		&w,
		{
			token = ag.token,
			agent_id = ag.agent_id,
			region = ag.region,
			capacity = u8(ag.capacity),
			running = u8(children_running()),
		},
	)
	agent_send(buf[:w.off])
}
