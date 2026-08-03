package main

import "../protocol"

// The last N snapshots as sent, ring-indexed by tick -- the pool delta
// baselines are drawn from. One history per client, because with fog of war
// two clients no longer receive the same world: the present mask is filtered
// per viewer, so a shared history would hand a client a baseline it was never
// sent and every delta after it would decode against the wrong world.
//
// Cost is SNAPSHOT_RING x MAX_CLIENTS snapshots, a few hundred kilobytes.

Snap_History :: struct {
	ticks: [protocol.SNAPSHOT_RING]u32,
	snaps: [protocol.SNAPSHOT_RING]protocol.Snapshot,
}

snap_history: [MAX_CLIENTS]Snap_History

// Stores what a client was actually sent. Call it after the send, never
// before: a snapshot the MTU rejected is one the client cannot ack, and
// keeping it would only leave a baseline nobody holds.
snap_history_store :: proc(client: int, snap: ^protocol.Snapshot, tick: u32) {
	if client < 0 || client >= MAX_CLIENTS do return
	idx := tick % protocol.SNAPSHOT_RING
	snap_history[client].ticks[idx] = tick
	snap_history[client].snaps[idx] = snap^
}

// The snapshot this client was sent at exactly `tick`, if the ring still holds
// it. Tick 0 means "nothing acked yet" and is never a baseline.
snap_history_at :: proc(client: int, tick: u32) -> ^protocol.Snapshot {
	if tick == 0 do return nil
	if client < 0 || client >= MAX_CLIENTS do return nil
	idx := tick % protocol.SNAPSHOT_RING
	if snap_history[client].ticks[idx] != tick do return nil
	return &snap_history[client].snaps[idx]
}

// A slot is being reused. The tick check above already refuses a stale entry,
// and a fresh slot acks nothing until it has been sent something -- this is
// belt and braces, so the next occupant cannot inherit a baseline by acking a
// tick number it never saw.
snap_history_reset :: proc(client: int) {
	if client < 0 || client >= MAX_CLIENTS do return
	for &t in snap_history[client].ticks do t = 0
}
