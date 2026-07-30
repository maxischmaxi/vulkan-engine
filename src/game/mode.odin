package game

// The mode identity shared by every layer: the client asks the master for it,
// the master matches servers by it, the server configures its match from it.
// The server's Game_Mode config struct carries one of these as its id; this
// enum is only the name that travels.
Mode :: enum u8 {
	TDM  = 0,
	Comp = 1,
}

// MR12, shared words: the server routes rounds by them, the client HUD hints
// off them ("MATCH POINT", the halftime notice).
COMP_HALF_ROUNDS :: 12
COMP_WIN_ROUNDS :: 13

// Humans a full match of this mode holds (team size times two). The master
// caps lobby assembly with it before any server exists to report max_players.
mode_max_humans :: proc(m: Mode) -> int {
	switch m {
	case .TDM:
		return 10
	case .Comp:
		return 10
	}
	return 1
}
