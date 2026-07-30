package game

// The match's coarse state, shared because both ends need the same words for
// it: the server drives the transitions, the client renders them, the wire
// carries the u8 between them. The transition logic itself is the server's.
Match_Phase :: enum u8 {
	Idle, // waiting for a human to join
	Countdown, // players placed, movement frozen, clock about to start
	Live, // the match proper; in comp, the round proper
	Post, // final scores up, nobody moves, menu next
	// Competitive, appended so TDM's wire values stay where they were.
	Warmup, // free play, infinite money, respawns; ends into round 1
	Freeze, // feet frozen, buy menu open, round about to start
	Bomb, // planted: the round clock is the fuse now
	Round_End, // round decided, scores up for a beat
	Halftime, // sides about to swap
}

// The phases in which feet move and triggers work. One name instead of a
// scatter of `== .Live` checks, so a new phase cannot silently disagree
// between the two binaries.
phase_is_action :: proc(p: Match_Phase) -> bool {
	return p == .Live || p == .Bomb || p == .Warmup
}

// The phases a buy is delivered in immediately. TDM additionally accepts buys
// during .Live and applies them on respawn; that exception is the mode's, not
// the phase's, so it lives with the buy rules, not here.
phase_can_buy :: proc(p: Match_Phase) -> bool {
	return p == .Freeze || p == .Warmup || p == .Countdown
}

// Why a round ended -- rides the Match_Phase message so the client can put a
// reason under the winner banner. Match_Over marks the message that ends the
// whole match (comp: score reached, TDM: clock ran out).
Round_End_Reason :: enum u8 {
	None,
	Elimination,
	Bomb_Exploded,
	Bomb_Defused,
	Time_Out,
	Match_Over,
}

// Wire sentinel for Match_Phase_Msg.winner: no winner named.
NO_WINNER :: u8(0xFF)
