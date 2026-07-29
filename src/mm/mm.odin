package mm

import "../protocol"

// The control-plane wire contract between game servers, the fleet agent, the
// master and the client. Unlike the game protocol this is stateless: every
// datagram stands alone, nothing is acknowledged, and the master's registry is
// soft state rebuilt from heartbeats -- losing a datagram costs at most one
// heartbeat interval.
//
// Server and agent traffic carries a shared-secret token; the master silently
// drops datagrams whose token does not match. Client queries are
// unauthenticated and answered only with data the servers advertise anyway.

MM_MAGIC :: u16(0x4D53)
MM_VERSION :: u8(1)

MM_DEFAULT_PORT :: 27050

// Largest control datagram by far is a Server_Heartbeat at ~90 bytes.
MM_MAX_DATAGRAM :: 256

// Servers and agents heartbeat at this cadence; an entry the master has not
// heard from for the TTL is treated as crashed and dropped.
HEARTBEAT_SECONDS :: 2.0
ENTRY_TTL_SECONDS :: 7.0

// A spawned server must send its first heartbeat within this window (covers
// world bake plus Steam logon), or the master frees the pending slot.
SPAWN_TIMEOUT_SECONDS :: 20.0

// After handing a server to a client, the master keeps it off the menu this
// long so two concurrent queries cannot land on the same instance.
RESERVE_SECONDS :: 10.0

// The client resends Find_Server until answered with Ok, then gives up.
CLIENT_RETRY_SECONDS :: 1.0
CLIENT_GIVEUP_SECONDS :: 30.0

Mm_Msg :: enum u8 {
	Invalid          = 0x00,
	// server -> master
	Server_Heartbeat = 0x01,
	Server_Bye       = 0x02,
	// master -> server
	Server_Drain     = 0x03,
	// agent -> master
	Agent_Heartbeat  = 0x10,
	Spawn_Result     = 0x12,
	// master -> agent
	Spawn_Server     = 0x11,
	Stop_Server      = 0x13,
	// client -> master
	Find_Server      = 0x20,
	// master -> client
	Find_Response    = 0x21,
}

Find_Status :: enum u8 {
	Ok          = 0,
	Spawning    = 1, // an instance is booting; keep retrying
	No_Capacity = 2, // no joinable server and no agent slot to spawn one
}

// Which transports the querying client can actually use. A STEAM_REQUIRED
// client sets Steam only; a dev client sets both.
ACCEPT_UDP :: u8(1 << 0)
ACCEPT_STEAM :: u8(1 << 1)

MM_TOKEN_LEN :: 32

Token :: [MM_TOKEN_LEN]u8

token_from_string :: proc(s: string) -> (t: Token) {
	copy(t[:], s)
	return
}

MM_MAX_REGION :: 16

// Fixed block plus length, zero-padded past len, so two regions compare with
// plain ==.
Region :: struct {
	data: [MM_MAX_REGION]u8,
	len:  u8,
}

region_from_string :: proc(s: string) -> (reg: Region) {
	reg.len = u8(copy(reg.data[:], s))
	return
}

// Borrows the backing array; valid as long as the Region it came from.
region_string :: proc(reg: ^Region) -> string {
	return string(reg.data[:reg.len])
}

Addr_Kind :: enum u8 {
	Udp   = 0,
	Steam = 1,
}

// Where clients reach a game server: a SteamID64 (release, SDR) or ip:port
// (dev/insecure). A heartbeating Udp server leaves ip4 zero unless it was
// started with -advertise; the master then substitutes the datagram's source
// address, which is right for every same-side-of-NAT topology.
Server_Addr :: struct {
	kind:     Addr_Kind,
	steam_id: u64,
	ip4:      [4]u8,
	port:     u16,
}

// ------------------------------------------------------------------ framing

Writer :: protocol.Writer
Reader :: protocol.Reader
writer :: protocol.writer
reader :: protocol.reader

// Every datagram: magic u16, version u8, msg u8, then the message payload.
frame_begin :: proc(w: ^Writer, msg: Mm_Msg) {
	protocol.write_u16(w, MM_MAGIC)
	protocol.write_u8(w, MM_VERSION)
	protocol.write_u8(w, u8(msg))
}

frame_open :: proc(data: []u8) -> (r: Reader, msg: Mm_Msg, ok: bool) {
	r = protocol.reader(data)
	magic := protocol.read_u16(&r)
	version := protocol.read_u8(&r)
	msg = Mm_Msg(protocol.read_u8(&r))
	if r.error || magic != MM_MAGIC || version != MM_VERSION {
		return r, .Invalid, false
	}
	return r, msg, true
}
