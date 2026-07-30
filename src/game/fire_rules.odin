package game

// Whether a pawn may pull the trigger at all -- a match rule, not a weapon
// state. Both binaries ask this one proc: the client so the muzzle stays dark
// exactly where the server would refuse the shot, the server because the
// client's answer is only ever a courtesy and this one is the fact.
//
// Keeping the rule here, beside the simulation both ends share, is what stops
// the two from drifting apart -- the whole reason a countdown could be shot
// through in the first place was that each end had its own opinion.

// Why the trigger was refused. A reason rather than a bool because the server
// counts refusals: a client that keeps sending Fire outside a live match is
// not running the code we shipped.
Fire_Block :: enum u8 {
	None,
	Not_In_Match, // idle, countdown or post -- the clock is not running
	Dead,
}

pawn_fire_block :: proc(phase: Match_Phase, p: ^Pawn) -> Fire_Block {
	if !p.active || !phase_is_action(phase) do return .Not_In_Match
	if !p.alive do return .Dead
	return .None
}

pawn_may_fire :: proc(phase: Match_Phase, p: ^Pawn) -> bool {
	return pawn_fire_block(phase, p) == .None
}
