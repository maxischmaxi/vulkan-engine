package anticheat

import "core:testing"

// ------------------------------------------------------------------ ban file

@(test)
ban_line_roundtrip :: proc(t: ^testing.T) {
	b := Ban_Line {
		steam_id = 76561198000000001,
		owner_id = 76561198000000002,
		ip       = 0x7F000001, // 127.0.0.1
		reason   = .Debug_Message,
		stamp    = 1753776000,
	}
	buf: [128]u8
	line, ok := format_ban_line(b, buf[:])
	testing.expect(t, ok)

	parsed, pok := parse_ban_line(line)
	testing.expect(t, pok)
	testing.expect_value(t, parsed, b)
}

@(test)
ban_line_zero_fields_roundtrip :: proc(t: ^testing.T) {
	// A UDP peer's ban: no steam identity, only an address.
	b := Ban_Line {
		ip     = 0x7F000001,
		reason = .Packet_Flood,
		stamp  = 1753776000,
	}
	buf: [128]u8
	line, ok := format_ban_line(b, buf[:])
	testing.expect(t, ok)

	parsed, pok := parse_ban_line(line)
	testing.expect(t, pok)
	testing.expect_value(t, parsed, b)
}

@(test)
ban_line_tolerates_hand_edits :: proc(t: ^testing.T) {
	b, ok := parse_ban_line("  76561198000000001   0  0.0.0.0   No_Recoil  1753776000  ")
	testing.expect(t, ok)
	testing.expect_value(t, b.steam_id, u64(76561198000000001))
	testing.expect_value(t, b.reason, Violation.No_Recoil)
}

@(test)
ban_line_rejects_junk :: proc(t: ^testing.T) {
	junk := []string {
		"",
		"   ",
		"# a comment the operator left",
		"76561198000000001", // torn append
		"76561198000000001 0 0.0.0.0 Debug_Message", // missing stamp
		"notanumber 0 0.0.0.0 Debug_Message 0",
		"1 0 0.0.0.0 Not_A_Violation 0",
		"1 0 999.0.0.1 Debug_Message 0", // ip octet out of range
		"1 0 1.2.3 Debug_Message 0", // short ip
		"1 0 0.0.0.0 Debug_Message 0 extra", // trailing field
	}
	for line in junk {
		_, ok := parse_ban_line(line)
		testing.expectf(t, !ok, "should have rejected: %q", line)
	}
}

// ------------------------------------------------------------------- verdict

@(test)
human_profile_stays_clean :: proc(t: ^testing.T) {
	// A long, sweaty but honest session: flicks, loose spray control, a few
	// phase-change stragglers. Must never produce a verdict.
	s := Aim_Stats {
		fired         = 400,
		hits          = 180,
		snap_count    = 40, // 10% flicks
		comp_shots    = 300,
		comp_r        = 0.85, // good spray control, far from machine
		perfect_shots = 30,
		norecoil_hits = 0,
		fire_denied   = 3,
		future_inputs = 40, // a server stall burst; judged by nobody
		backlog_trims = 5,
	}
	testing.expect_value(t, evaluate(s), Violation.None)
}

@(test)
small_sample_never_fires :: proc(t: ^testing.T) {
	// Blatant numbers below the sample floor: no verdict, however damning.
	s := Aim_Stats {
		fired         = EVAL_MIN_FIRED - 1,
		snap_count    = EVAL_MIN_FIRED - 1,
		comp_shots    = EVAL_MIN_FIRED - 1,
		comp_r        = 1.0,
		norecoil_hits = EVAL_NORECOIL_HITS - 1,
	}
	testing.expect_value(t, evaluate(s), Violation.None)
}

@(test)
boundaries_stay_clean :: proc(t: ^testing.T) {
	// Every signal exactly at its threshold; each check is strictly beyond.
	s := Aim_Stats {
		fired         = 100,
		snap_count    = 25, // ratio exactly EVAL_SNAP_RATIO
		comp_shots    = 100,
		comp_r        = EVAL_COMP_R,
		perfect_shots = 50, // ratio exactly EVAL_PERFECT_RATIO
		norecoil_hits = EVAL_NORECOIL_HITS - 1,
		fire_denied   = EVAL_FIRE_DENIED,
	}
	testing.expect_value(t, evaluate(s), Violation.None)
}

@(test)
detects_recoil_script :: proc(t: ^testing.T) {
	s := Aim_Stats {
		fired      = 100,
		comp_shots = 100,
		comp_r     = 0.999,
	}
	testing.expect_value(t, evaluate(s), Violation.Recoil_Script)
}

@(test)
detects_pattern_mirror :: proc(t: ^testing.T) {
	// Not correlated enough for comp_r, but half the pulls are pixel-perfect.
	s := Aim_Stats {
		fired         = 100,
		comp_shots    = 80,
		comp_r        = 0.9,
		perfect_shots = 60,
	}
	testing.expect_value(t, evaluate(s), Violation.Recoil_Script)
}

@(test)
detects_no_recoil :: proc(t: ^testing.T) {
	s := Aim_Stats {
		fired         = 60,
		norecoil_hits = 20,
	}
	testing.expect_value(t, evaluate(s), Violation.No_Recoil)
}

@(test)
detects_aim_snap :: proc(t: ^testing.T) {
	s := Aim_Stats {
		fired      = 100,
		hits       = 95,
		snap_count = 80,
	}
	testing.expect_value(t, evaluate(s), Violation.Aim_Snap)
}

@(test)
detects_fire_desync :: proc(t: ^testing.T) {
	// Needs no aim sample at all; the count alone convicts.
	s := Aim_Stats {
		fire_denied = EVAL_FIRE_DENIED + 1,
	}
	testing.expect_value(t, evaluate(s), Violation.Fire_Desync)
}
