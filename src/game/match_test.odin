package game

import "core:testing"

// The phase predicates are the one place a new phase declares what it means;
// every gate in both binaries reads them. These tables are the ripple guard:
// an enumerated array cannot compile with a phase missing, so adding one
// forces a decision here first.

@(test)
test_phase_predicates :: proc(t: ^testing.T) {
	action := [Match_Phase]bool {
		.Idle      = false,
		.Countdown = false,
		.Live      = true,
		.Post      = false,
		.Warmup    = true,
		.Freeze    = false,
		.Bomb      = true,
		.Round_End = false,
		.Halftime  = false,
	}
	buy := [Match_Phase]bool {
		.Idle      = false,
		.Countdown = true,
		.Live      = false, // TDM's mid-match buy is the mode's exception
		.Post      = false,
		.Warmup    = true,
		.Freeze    = true,
		.Bomb      = false,
		.Round_End = false,
		.Halftime  = false,
	}

	for phase in Match_Phase {
		testing.expectf(
			t,
			phase_is_action(phase) == action[phase],
			"phase_is_action({}) should be {}",
			phase,
			action[phase],
		)
		testing.expectf(
			t,
			phase_can_buy(phase) == buy[phase],
			"phase_can_buy({}) should be {}",
			phase,
			buy[phase],
		)
	}
}
