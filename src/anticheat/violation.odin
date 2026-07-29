// The anti-cheat core: pure decisions over plain numbers, shared between the
// server and its tests. No sockets, no slots, no Steam -- the same reason the
// lag compensation lives in the shared game package: testable without a wire.
package anticheat

// What a detector concluded, split by certainty. Hard violations are protocol
// impossibilities -- the shipped client cannot produce them, so they ban
// unconditionally. Statistical violations come from thresholds over telemetry
// and respect the server's shadow switch.
Violation :: enum u8 {
	None,
	Debug_Message, // Debug_Flags reached a hardened server: modified client
	Packet_Flood, // per-peer datagram budget exceeded for consecutive windows
	Ban_Evasion, // connected on the library of a banned family-sharing owner
	Input_Time_Travel, // reserved: future-tick inputs, telemetry only today
	Fire_Desync, // trigger pulls the shipped client strips off the wire itself
	Aim_Snap, // flicks onto targets beyond human step rate, sustained
	Recoil_Script, // spray compensation correlated like a machine
	No_Recoil, // hits while ignoring a pattern that demanded degrees of pull
}

violation_hard :: proc(v: Violation) -> bool {
	#partial switch v {
	case .Debug_Message, .Packet_Flood, .Ban_Evasion:
		return true
	}
	return false
}
