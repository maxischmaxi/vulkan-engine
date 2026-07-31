package protocol

// The wire contract between client and server. Hand-rolled over UDP in the
// Quake tradition: one datagram per packet, a small header carrying sequence
// and acknowledgement state, an optional reliable block, then unreliable
// messages to the end of the datagram.
//
// Three channels ride on this:
//   - inputs, client to server: unreliable, redundant (each packet carries the
//     last few commands), sequenced by the header
//   - snapshots, server to client: unreliable, delta-encoded against the
//     newest snapshot the client acknowledged -- never against the last one
//     sent, so a lost snapshot costs nothing and needs no repair
//   - control, both ways: reliable-ordered via the piggyback window in
//     connection.odin (join, match phases, kills, disconnects)

PROTOCOL_MAGIC :: u16(0xB0F5)
PROTOCOL_VERSION :: u8(12)

// Well under every real-world MTU, so a packet is never fragmented. The worst
// snapshot today is ~400 bytes; this is headroom, not a target.
MTU :: 1200

DEFAULT_PORT :: 27015

// Seconds without a packet before either side declares the other gone.
TIMEOUT_SECONDS :: 5.0

// How often the client retries the handshake, and how many times.
CONNECT_RETRY_SECONDS :: 0.5
CONNECT_MAX_TRIES :: 10

// Snapshots go every Nth tick. 1 = full tick rate; the one-line throttle if
// bandwidth ever matters.
SNAPSHOT_DIVISOR :: 1

// How many redundant commands an input packet carries: survives that many
// consecutive lost packets minus one.
INPUT_REDUNDANCY :: 8

// How far behind the newest snapshot the client renders remote entities.
// Shared because the server rewinds hitboxes by exactly this much when
// resolving a human's shot (lag compensation).
INTERP_TICKS :: 6

// Depth of the snapshot rings on both ends: the client keeps the last N
// received, the server the last N sent. Shared so the server can never pick a
// delta baseline the client already overwrote.
SNAPSHOT_RING :: 32

Msg_Id :: enum u8 {
	Invalid           = 0x00,
	// client -> server
	Connect_Request   = 0x01,
	Keepalive         = 0x02,
	Input             = 0x03,
	Join              = 0x04, // reliable
	Disconnect        = 0x05,
	Debug_Flags       = 0x06, // reliable; a dev affordance a hardened server refuses
	Loadout           = 0x07, // reliable; a buy must not be lost
	Practice          = 0x08, // reliable; the server tracks who is on the range
	AC_Response       = 0x09, // reliable; reserved for the future integrity channel
	// server -> client
	Connect_Accept    = 0x10,
	Connect_Deny      = 0x11,
	Snapshot          = 0x12,
	Match_Phase       = 0x13, // reliable
	Kill              = 0x14, // reliable
	Server_Disconnect = 0x15,
	Damage            = 0x16, // unreliable, victim only
	AC_Challenge      = 0x17, // reliable; reserved, no server sends one today
	Roster            = 0x18, // reliable; names and K/D for the scoreboard
}

Deny_Reason :: enum u8 {
	None         = 0,
	Full         = 1,
	Bad_Version  = 2,
	In_Match     = 3,
	Bad_Ticket   = 4,
	No_License   = 5,
	Banned       = 6,
	Auth_Timeout = 7,
}

Disconnect_Reason :: enum u8 {
	None         = 0,
	Quit         = 1,
	Timeout      = 2,
	Shutdown     = 3,
	Kicked       = 4,
	Auth_Revoked = 5,
	Banned       = 6, // anti-cheat verdict: permanent, the ban list already holds it
}

// Steam transport only: deny/disconnect reasons mirrored into the connection
// close handshake (ESteamNetConnectionEnd app range 1000..1999), because the
// deny/disconnect datagrams themselves are unreliable and may not arrive.
CLOSE_CODE_DENY_BASE :: 1000
CLOSE_CODE_DISCONNECT_BASE :: 1100
