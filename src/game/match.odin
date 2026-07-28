package game

// The match's coarse state, shared because both ends need the same words for
// it: the server drives the transitions, the client renders them, the wire
// carries the u8 between them. The transition logic itself is the server's.
Match_Phase :: enum u8 {
	Idle, // waiting for a human to join
	Countdown, // players placed, movement frozen, clock about to start
	Live, // the match proper
	Post, // final scores up, nobody moves, menu next
}
