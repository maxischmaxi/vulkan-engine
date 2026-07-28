package main

import "../protocol"
import "core:log"

// The server's whole knowledge of the practice range: who is on it. The range
// itself is simulated by the client; the flag exists so future matchmaking can
// offer a game to someone warming up. Deliberately no pawn, no phase, no
// snapshot changes -- the slot stays .Connected.

handle_practice :: proc(slot: ^Client_Slot, m: protocol.Practice_Msg) {
	slot.practice = m.entering
	log.infof(
		"Server: client {} {} practice",
		client_index(slot),
		m.entering ? "entered" : "left",
	)
}
