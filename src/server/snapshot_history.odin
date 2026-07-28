package main

import "../protocol"

// The last N snapshots as sent, ring-indexed by tick -- the pool delta
// baselines are drawn from. One shared history is enough: per-client
// snapshots differ only in last_input_tick and the private block, and both
// always travel in full.

Snap_History :: struct {
	ticks: [protocol.SNAPSHOT_RING]u32,
	snaps: [protocol.SNAPSHOT_RING]protocol.Snapshot,
}

snap_history: Snap_History

snap_history_store :: proc(snap: ^protocol.Snapshot, tick: u32) {
	idx := tick % protocol.SNAPSHOT_RING
	snap_history.ticks[idx] = tick
	snap_history.snaps[idx] = snap^
}

// The snapshot sent at exactly `tick`, if the ring still holds it. Tick 0
// means "nothing acked yet" and is never a baseline.
snap_history_at :: proc(tick: u32) -> ^protocol.Snapshot {
	if tick == 0 do return nil
	idx := tick % protocol.SNAPSHOT_RING
	if snap_history.ticks[idx] != tick do return nil
	return &snap_history.snaps[idx]
}
