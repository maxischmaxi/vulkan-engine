package mm

import "../game"
import "../protocol"

// One struct and one write/read pair per message, protocol/messages.odin
// style: the pair IS the wire format, MM_VERSION is the version of this file.
// Authenticated messages carry the token as their first field.

// Re-exported so every mm consumer serializes through one import.
write_u8 :: protocol.write_u8
write_u16 :: protocol.write_u16
write_u32 :: protocol.write_u32
write_bytes :: protocol.write_bytes
read_u8 :: protocol.read_u8
read_u16 :: protocol.read_u16
read_u32 :: protocol.read_u32
read_bytes :: protocol.read_bytes

@(private)
write_u64 :: proc(w: ^Writer, v: u64) {
	write_u32(w, u32(v))
	write_u32(w, u32(v >> 32))
}

@(private)
read_u64 :: proc(r: ^Reader) -> u64 {
	lo := u64(read_u32(r))
	hi := u64(read_u32(r))
	return lo | hi << 32
}

@(private)
write_token :: proc(w: ^Writer, t: Token) {
	t := t
	write_bytes(w, t[:])
}

@(private)
read_token :: proc(r: ^Reader) -> (t: Token) {
	read_bytes(r, t[:])
	return
}

@(private)
write_region :: proc(w: ^Writer, reg: Region) {
	write_u8(w, min(reg.len, MM_MAX_REGION))
	data := reg.data
	write_bytes(w, data[:])
}

@(private)
read_region :: proc(r: ^Reader) -> (reg: Region) {
	reg.len = min(read_u8(r), MM_MAX_REGION)
	read_bytes(r, reg.data[:])
	return
}

write_server_addr :: proc(w: ^Writer, a: Server_Addr) {
	write_u8(w, u8(a.kind))
	write_u64(w, a.steam_id)
	ip := a.ip4
	write_bytes(w, ip[:])
	write_u16(w, a.port)
}

read_server_addr :: proc(r: ^Reader) -> (a: Server_Addr) {
	a.kind = Addr_Kind(read_u8(r))
	a.steam_id = read_u64(r)
	read_bytes(r, a.ip4[:])
	a.port = read_u16(r)
	return
}

// ------------------------------------------------------- server <-> master

Server_Heartbeat :: struct {
	token:       Token,
	server_id:   u64,
	spawn_id:    u64, // 0 = hand-started, otherwise the agent spawn it came from
	region:      Region,
	addr:        Server_Addr,
	mode:        game.Mode, // what this server runs; the queue matches on it
	players:     u8,
	max_players: u8,
	phase:       u8, // raw match phase, master only logs it
	joinable:    bool,
	draining:    bool,
}

write_server_heartbeat :: proc(w: ^Writer, m: Server_Heartbeat) {
	write_token(w, m.token)
	write_u64(w, m.server_id)
	write_u64(w, m.spawn_id)
	write_region(w, m.region)
	write_server_addr(w, m.addr)
	write_u8(w, u8(m.mode))
	write_u8(w, m.players)
	write_u8(w, m.max_players)
	write_u8(w, m.phase)
	write_u8(w, m.joinable ? 1 : 0)
	write_u8(w, m.draining ? 1 : 0)
}

read_server_heartbeat :: proc(r: ^Reader) -> (m: Server_Heartbeat, ok: bool) {
	m.token = read_token(r)
	m.server_id = read_u64(r)
	m.spawn_id = read_u64(r)
	m.region = read_region(r)
	m.addr = read_server_addr(r)
	m.mode = game.Mode(read_u8(r))
	m.players = read_u8(r)
	m.max_players = read_u8(r)
	m.phase = read_u8(r)
	m.joinable = read_u8(r) != 0
	m.draining = read_u8(r) != 0
	return m, !r.error
}

// Sent redundantly on graceful exit so the entry dies now, not at TTL.
Server_Bye :: struct {
	token:     Token,
	server_id: u64,
}

write_server_bye :: proc(w: ^Writer, m: Server_Bye) {
	write_token(w, m.token)
	write_u64(w, m.server_id)
}

read_server_bye :: proc(r: ^Reader) -> (m: Server_Bye, ok: bool) {
	m.token = read_token(r)
	m.server_id = read_u64(r)
	return m, !r.error
}

// Master to a server's heartbeat endpoint: stop accepting joins, exit when
// empty. Resent every sweep until the entry disappears.
Server_Drain :: struct {
	token:     Token,
	server_id: u64,
}

write_server_drain :: proc(w: ^Writer, m: Server_Drain) {
	write_token(w, m.token)
	write_u64(w, m.server_id)
}

read_server_drain :: proc(r: ^Reader) -> (m: Server_Drain, ok: bool) {
	m.token = read_token(r)
	m.server_id = read_u64(r)
	return m, !r.error
}

// -------------------------------------------------------- agent <-> master

Agent_Heartbeat :: struct {
	token:    Token,
	agent_id: u64, // random at agent boot
	region:   Region,
	capacity: u8,
	running:  u8,
}

write_agent_heartbeat :: proc(w: ^Writer, m: Agent_Heartbeat) {
	write_token(w, m.token)
	write_u64(w, m.agent_id)
	write_region(w, m.region)
	write_u8(w, m.capacity)
	write_u8(w, m.running)
}

read_agent_heartbeat :: proc(r: ^Reader) -> (m: Agent_Heartbeat, ok: bool) {
	m.token = read_token(r)
	m.agent_id = read_u64(r)
	m.region = read_region(r)
	m.capacity = read_u8(r)
	m.running = read_u8(r)
	return m, !r.error
}

// The spawn_id is the correlation id end to end: the agent passes it to the
// child as -server-id, the child heartbeats it, the master's pending entry
// clears on it. Mode and expected_humans become the child's -mode= and
// -expected-humans= flags; zero expected means open quickplay.
Spawn_Server :: struct {
	token:           Token,
	spawn_id:        u64,
	mode:            game.Mode,
	expected_humans: u8,
}

write_spawn_server :: proc(w: ^Writer, m: Spawn_Server) {
	write_token(w, m.token)
	write_u64(w, m.spawn_id)
	write_u8(w, u8(m.mode))
	write_u8(w, m.expected_humans)
}

read_spawn_server :: proc(r: ^Reader) -> (m: Spawn_Server, ok: bool) {
	m.token = read_token(r)
	m.spawn_id = read_u64(r)
	m.mode = game.Mode(read_u8(r))
	m.expected_humans = read_u8(r)
	return m, !r.error
}

Spawn_Result :: struct {
	token:    Token,
	spawn_id: u64,
	ok:       bool,
	port:     u16,
}

write_spawn_result :: proc(w: ^Writer, m: Spawn_Result) {
	write_token(w, m.token)
	write_u64(w, m.spawn_id)
	write_u8(w, m.ok ? 1 : 0)
	write_u16(w, m.port)
}

read_spawn_result :: proc(r: ^Reader) -> (m: Spawn_Result, ok: bool) {
	m.token = read_token(r)
	m.spawn_id = read_u64(r)
	m.ok = read_u8(r) != 0
	m.port = read_u16(r)
	return m, !r.error
}

// Escalation path: the agent SIGTERMs that child, SIGKILL after a grace.
Stop_Server :: struct {
	token:     Token,
	server_id: u64,
}

write_stop_server :: proc(w: ^Writer, m: Stop_Server) {
	write_token(w, m.token)
	write_u64(w, m.server_id)
}

read_stop_server :: proc(r: ^Reader) -> (m: Stop_Server, ok: bool) {
	m.token = read_token(r)
	m.server_id = read_u64(r)
	return m, !r.error
}

// -------------------------------------------------------- client <-> master

Find_Server :: struct {
	nonce:        u32, // echoed in the response; stale answers are dropped
	region:       Region, // empty = any region
	game_version: u8, // protocol.PROTOCOL_VERSION of the asking client
	accepts:      u8, // ACCEPT_* bitmask
	mode:         game.Mode, // quickplay is mode-filtered too
}

write_find_server :: proc(w: ^Writer, m: Find_Server) {
	write_u32(w, m.nonce)
	write_region(w, m.region)
	write_u8(w, m.game_version)
	write_u8(w, m.accepts)
	write_u8(w, u8(m.mode))
}

read_find_server :: proc(r: ^Reader) -> (m: Find_Server, ok: bool) {
	m.nonce = read_u32(r)
	m.region = read_region(r)
	m.game_version = read_u8(r)
	m.accepts = read_u8(r)
	m.mode = game.Mode(read_u8(r))
	return m, !r.error
}

Find_Response :: struct {
	nonce:  u32,
	status: Find_Status,
	addr:   Server_Addr, // valid when status == .Ok
}

write_find_response :: proc(w: ^Writer, m: Find_Response) {
	write_u32(w, m.nonce)
	write_u8(w, u8(m.status))
	write_server_addr(w, m.addr)
}

read_find_response :: proc(r: ^Reader) -> (m: Find_Response, ok: bool) {
	m.nonce = read_u32(r)
	m.status = Find_Status(read_u8(r))
	m.addr = read_server_addr(r)
	return m, !r.error
}

// ----------------------------------------------------------- queue messages

// Enter and stay: sent once a second for as long as the player queues. The
// (source endpoint, nonce) pair IS the queue identity -- no account, no
// auth, the Find_Server trust model. Re-sending after a master restart
// re-enters transparently; going silent for QUEUE_TTL_SECONDS leaves.
Queue_Enter :: struct {
	nonce:        u32, // random per queue attempt
	region:       Region, // empty = any
	game_version: u8, // protocol.PROTOCOL_VERSION
	accepts:      u8, // ACCEPT_* bitmask
	mode:         game.Mode,
}

write_queue_enter :: proc(w: ^Writer, m: Queue_Enter) {
	write_u32(w, m.nonce)
	write_region(w, m.region)
	write_u8(w, m.game_version)
	write_u8(w, m.accepts)
	write_u8(w, u8(m.mode))
}

read_queue_enter :: proc(r: ^Reader) -> (m: Queue_Enter, ok: bool) {
	m.nonce = read_u32(r)
	m.region = read_region(r)
	m.game_version = read_u8(r)
	m.accepts = read_u8(r)
	m.mode = game.Mode(read_u8(r))
	return m, !r.error
}

// Courtesy cancel so the seat frees now, not at TTL. Sent a few times, best
// effort.
Queue_Leave :: struct {
	nonce: u32,
}

write_queue_leave :: proc(w: ^Writer, m: Queue_Leave) {
	write_u32(w, m.nonce)
}

read_queue_leave :: proc(r: ^Reader) -> (m: Queue_Leave, ok: bool) {
	m.nonce = read_u32(r)
	return m, !r.error
}

// The answer to every Queue_Enter while no server is assigned. queued and
// needed let the UI say "2 OF 5" without the master promising anything.
Queue_Reply :: struct {
	nonce:  u32,
	status: Queue_Status,
	queued: u8, // humans currently grouped with you (same mode and region)
	needed: u8, // the master's min-humans threshold
}

write_queue_reply :: proc(w: ^Writer, m: Queue_Reply) {
	write_u32(w, m.nonce)
	write_u8(w, u8(m.status))
	write_u8(w, m.queued)
	write_u8(w, m.needed)
}

read_queue_reply :: proc(r: ^Reader) -> (m: Queue_Reply, ok: bool) {
	m.nonce = read_u32(r)
	m.status = Queue_Status(read_u8(r))
	m.queued = read_u8(r)
	m.needed = read_u8(r)
	return m, !r.error
}

// The match: sent unsolicited at assignment and again in answer to every
// further Queue_Enter until the entry dies, so a lost datagram costs one
// resend interval. match_id correlates logs; with no client auth the server
// cannot enforce it anyway.
Match_Assign :: struct {
	nonce:    u32,
	match_id: u64,
	addr:     Server_Addr,
}

write_match_assign :: proc(w: ^Writer, m: Match_Assign) {
	write_u32(w, m.nonce)
	write_u64(w, m.match_id)
	write_server_addr(w, m.addr)
}

read_match_assign :: proc(r: ^Reader) -> (m: Match_Assign, ok: bool) {
	m.nonce = read_u32(r)
	m.match_id = read_u64(r)
	m.addr = read_server_addr(r)
	return m, !r.error
}
