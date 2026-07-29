package anticheat

// A snapshot of the server's per-slot accumulators, copied in by the caller as
// plain numbers -- this package knows no server types.
Aim_Stats :: struct {
	fired:         int,
	hits:          int,
	snap_count:    int, // firing-tick flicks over the snap threshold
	comp_shots:    int, // spray shots with real pattern deviation
	comp_r:        f64, // player pull vs inverse pattern correlation
	perfect_shots: int, // pulls mirroring the pattern within quantizer noise
	norecoil_hits: int, // hits with degrees demanded and none pulled
	fire_denied:   int, // trigger pulls the shipped client strips itself
	// Collected but not judged: a future-tick input yields no advantage (the
	// server refuses to store it), and a server stall makes honest clients
	// produce bursts of them because the input clock never re-anchors after
	// the accept. Telemetry until that clock learns to re-sync.
	future_inputs: int,
	backlog_trims: int, // same: a fast client clock loses commands, gains nothing
}

// Deliberately extreme thresholds: enforcement is live from day one, so every
// value sits far past anything a human produces. The shadow switch exists to
// calibrate them tighter against real play before they move.
EVAL_MIN_FIRED :: 50 // no statistical verdict below this sample size
EVAL_SNAP_RATIO :: 0.25 // flicks over 20 deg per shot, sustained
EVAL_COMP_MIN_SHOTS :: 60
EVAL_COMP_R :: 0.985 // compensation correlation over those shots
EVAL_PERFECT_RATIO :: 0.5 // pattern mirrored within noise, half of all shots
EVAL_NORECOIL_HITS :: 8
EVAL_FIRE_DENIED :: 200 // far past what phase-change stragglers can reach

// The statistical detector: reads the accumulators, names the strongest
// violation, .None while everything stays inside the thresholds.
//
// Server bots never get here -- they own no client slot and therefore no
// accumulators. If bots ever move onto slots, this needs a bot profile first.
evaluate :: proc(s: Aim_Stats) -> Violation {
	// Needs no aim sample: the count only exists on a client that stopped
	// stripping refused triggers, and the grace threshold is far past what
	// phase-change latency produces on an honest one.
	if s.fire_denied > EVAL_FIRE_DENIED do return .Fire_Desync

	if s.fired < EVAL_MIN_FIRED do return .None
	if s.norecoil_hits >= EVAL_NORECOIL_HITS do return .No_Recoil
	if s.comp_shots >= EVAL_COMP_MIN_SHOTS {
		if s.comp_r > EVAL_COMP_R do return .Recoil_Script
		if f64(s.perfect_shots) / f64(s.comp_shots) > EVAL_PERFECT_RATIO do return .Recoil_Script
	}
	if f64(s.snap_count) / f64(s.fired) > EVAL_SNAP_RATIO do return .Aim_Snap
	return .None
}
