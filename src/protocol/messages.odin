package protocol

import "../game"

// One struct and one write/read pair per message. The pair IS the wire format:
// there is no schema beyond this file, and PROTOCOL_VERSION is the version of
// this file. Message ids are written by the caller (the packet framing owns
// them); these procs carry the payload only.

MAX_NAME :: 16

// A Steam auth session ticket. Real tickets run ~234 bytes; the cap is the
// SDK's own buffer recommendation. Zero-length means an insecure dev connect.
MAX_TICKET :: 1024

Connect_Request :: struct {
	client_salt: u32,
	name:        [MAX_NAME]u8,
	name_len:    u8,
	ticket:      [MAX_TICKET]u8,
	ticket_len:  u16,
}

write_connect_request :: proc(w: ^Writer, m: Connect_Request) {
	write_u32(w, m.client_salt)
	write_u8(w, min(m.name_len, MAX_NAME))
	name := m.name
	write_bytes(w, name[:])
	// Unlike the fixed name block, the ticket goes out length-prefixed and
	// trimmed: padding it to MAX_TICKET would put every handshake at the MTU.
	tlen := min(m.ticket_len, MAX_TICKET)
	write_u16(w, tlen)
	ticket := m.ticket
	write_bytes(w, ticket[:tlen])
}

read_connect_request :: proc(r: ^Reader) -> (m: Connect_Request, ok: bool) {
	m.client_salt = read_u32(r)
	m.name_len = min(read_u8(r), MAX_NAME)
	read_bytes(r, m.name[:])
	m.ticket_len = min(read_u16(r), MAX_TICKET)
	read_bytes(r, m.ticket[:m.ticket_len])
	return m, !r.error
}

Connect_Accept :: struct {
	server_salt: u32,
	server_tick: u32,
	pawn_id:     u8,
	tick_rate:   u8,
	phase:       game.Match_Phase,
	mode:        game.Mode, // what this server runs; the HUD branches on it
}

write_connect_accept :: proc(w: ^Writer, m: Connect_Accept) {
	write_u32(w, m.server_salt)
	write_u32(w, m.server_tick)
	write_u8(w, m.pawn_id)
	write_u8(w, m.tick_rate)
	write_u8(w, u8(m.phase))
	write_u8(w, u8(m.mode))
}

read_connect_accept :: proc(r: ^Reader) -> (m: Connect_Accept, ok: bool) {
	m.server_salt = read_u32(r)
	m.server_tick = read_u32(r)
	m.pawn_id = read_u8(r)
	m.tick_rate = read_u8(r)
	m.phase = game.Match_Phase(read_u8(r))
	m.mode = game.Mode(read_u8(r))
	return m, !r.error
}

Connect_Deny :: struct {
	reason: Deny_Reason,
}

write_connect_deny :: proc(w: ^Writer, m: Connect_Deny) {
	write_u8(w, u8(m.reason))
}

read_connect_deny :: proc(r: ^Reader) -> (m: Connect_Deny, ok: bool) {
	m.reason = Deny_Reason(read_u8(r))
	return m, !r.error
}

Join :: struct {
	team: game.Team,
}

write_join :: proc(w: ^Writer, m: Join) {
	write_u8(w, u8(m.team))
}

read_join :: proc(r: ^Reader) -> (m: Join, ok: bool) {
	m.team = game.Team(read_u8(r))
	return m, !r.error
}

Join_Deny_Msg :: struct {
	reason: Join_Deny_Reason,
}

write_join_deny :: proc(w: ^Writer, m: Join_Deny_Msg) {
	write_u8(w, u8(m.reason))
}

read_join_deny :: proc(r: ^Reader) -> (m: Join_Deny_Msg, ok: bool) {
	m.reason = Join_Deny_Reason(read_u8(r))
	return m, !r.error
}

// The client's debug toggles, mirrored to the server so god mode and infinite
// ammo mean something against an authoritative simulation. Development only:
// the message exists to be refused by a server that takes cheating seriously.
Debug_Flags :: struct {
	god:           bool,
	infinite_ammo: bool,
}

write_debug_flags :: proc(w: ^Writer, m: Debug_Flags) {
	flags: u8 = 0
	if m.god do flags |= 1 << 0
	if m.infinite_ammo do flags |= 1 << 1
	write_u8(w, flags)
}

read_debug_flags :: proc(r: ^Reader) -> (m: Debug_Flags, ok: bool) {
	flags := read_u8(r)
	m.god = flags & (1 << 0) != 0
	m.infinite_ammo = flags & (1 << 1) != 0
	return m, !r.error
}

// The buy menu's choice: what the next spawn carries, applied immediately
// during the countdown. Validation is the server's job; the wire only moves
// three bytes.
Loadout_Msg :: struct {
	primary:   i8, // WEAPONS index, -1 = none
	secondary: i8,
	armor:     bool,
}

write_loadout :: proc(w: ^Writer, m: Loadout_Msg) {
	write_u8(w, transmute(u8)m.primary)
	write_u8(w, transmute(u8)m.secondary)
	write_u8(w, m.armor ? 1 : 0)
}

read_loadout :: proc(r: ^Reader) -> (m: Loadout_Msg, ok: bool) {
	m.primary = transmute(i8)read_u8(r)
	m.secondary = transmute(i8)read_u8(r)
	m.armor = read_u8(r) != 0
	return m, !r.error
}

// Sent instead of Join by a client entering the practice range. The server
// only records it -- the range is simulated on the client -- but the flag is
// the seam future matchmaking-from-practice hangs off. `entering = false` is
// reserved for the practice-to-lobby hop once that exists.
Practice_Msg :: struct {
	entering: bool,
}

write_practice :: proc(w: ^Writer, m: Practice_Msg) {
	write_u8(w, m.entering ? 1 : 0)
}

read_practice :: proc(r: ^Reader) -> (m: Practice_Msg, ok: bool) {
	m.entering = read_u8(r) != 0
	return m, !r.error
}

Disconnect :: struct {
	reason: Disconnect_Reason,
}

write_disconnect :: proc(w: ^Writer, m: Disconnect) {
	write_u8(w, u8(m.reason))
}

read_disconnect :: proc(r: ^Reader) -> (m: Disconnect, ok: bool) {
	m.reason = Disconnect_Reason(read_u8(r))
	return m, !r.error
}

Match_Phase_Msg :: struct {
	phase:      game.Match_Phase,
	// The server tick at which this phase ends (0 if open-ended). The client
	// derives its countdown and match clocks from it.
	param_tick: u32,
	t_score:    u8,
	ct_score:   u8,
	// Comp round bookkeeping; TDM sends round 0, NO_WINNER, reason None
	// (except the final Post, whose reason is Match_Over in both modes).
	round:      u8,
	winner:     u8, // game.Team of the round winner; game.NO_WINNER = none
	reason:     game.Round_End_Reason,
}

write_match_phase :: proc(w: ^Writer, m: Match_Phase_Msg) {
	write_u8(w, u8(m.phase))
	write_u32(w, m.param_tick)
	write_u8(w, m.t_score)
	write_u8(w, m.ct_score)
	write_u8(w, m.round)
	write_u8(w, m.winner)
	write_u8(w, u8(m.reason))
}

read_match_phase :: proc(r: ^Reader) -> (m: Match_Phase_Msg, ok: bool) {
	m.phase = game.Match_Phase(read_u8(r))
	m.param_tick = read_u32(r)
	m.t_score = read_u8(r)
	m.ct_score = read_u8(r)
	m.round = read_u8(r)
	m.winner = read_u8(r)
	m.reason = game.Round_End_Reason(read_u8(r))
	return m, !r.error
}

// The roster: every active pawn's name and score, broadcast edge-triggered
// (join, kill, drop, bot claim). Bots carry an empty name; the client labels
// them itself. The binding limit is not the MTU but the 64-byte reliable slot:
// a full roster must go out in chunks (roster_chunk_split); the client merges
// per entry, so partial rosters compose.
Roster_Entry :: struct {
	pawn_id:  u8,
	kills:    u8,
	deaths:   u8,
	name_len: u8,
	name:     [MAX_NAME]u8,
}

Roster :: struct {
	count:   u8,
	entries: [game.MAX_PAWNS]Roster_Entry,
}

write_roster :: proc(w: ^Writer, m: Roster) {
	count := min(m.count, u8(game.MAX_PAWNS))
	write_u8(w, count)
	for i in 0 ..< int(count) {
		e := m.entries[i]
		write_u8(w, e.pawn_id)
		write_u8(w, e.kills)
		write_u8(w, e.deaths)
		nlen := min(e.name_len, MAX_NAME)
		write_u8(w, nlen)
		name := e.name
		write_bytes(w, name[:nlen])
	}
}

read_roster :: proc(r: ^Reader) -> (m: Roster, ok: bool) {
	m.count = min(read_u8(r), u8(game.MAX_PAWNS))
	for i in 0 ..< int(m.count) {
		e: Roster_Entry
		e.pawn_id = read_u8(r)
		e.kills = read_u8(r)
		e.deaths = read_u8(r)
		e.name_len = min(read_u8(r), MAX_NAME)
		read_bytes(r, e.name[:e.name_len])
		m.entries[i] = e
	}
	return m, !r.error
}

// Fixed bytes per entry on the wire: pawn_id, kills, deaths, name_len.
ROSTER_ENTRY_BYTES :: 4

// Worst case: MAX_PAWNS entries with full names, 3 to a chunk.
MAX_ROSTER_CHUNKS :: 6

// Splits a roster into chunks that each fit a reliable slot. Greedy packing;
// returns the chunk count, 0 for an empty roster.
roster_chunk_split :: proc(full: Roster, chunks: []Roster) -> int {
	count := 0
	used := MAX_RELIABLE_PAYLOAD // forces a fresh chunk on the first entry
	for i in 0 ..< int(min(full.count, u8(game.MAX_PAWNS))) {
		e := full.entries[i]
		size := ROSTER_ENTRY_BYTES + int(min(e.name_len, MAX_NAME))
		if used + size > MAX_RELIABLE_PAYLOAD {
			if count >= len(chunks) do break
			chunks[count] = {}
			count += 1
			used = 1 // the count byte
		}
		chunk := &chunks[count - 1]
		chunk.entries[chunk.count] = e
		chunk.count += 1
		used += size
	}
	return count
}

Kill :: struct {
	killer: u8, // pawn id, 0xFF = the world
	victim: u8,
	weapon: u8,
}

write_kill :: proc(w: ^Writer, m: Kill) {
	write_u8(w, m.killer)
	write_u8(w, m.victim)
	write_u8(w, m.weapon)
}

read_kill :: proc(r: ^Reader) -> (m: Kill, ok: bool) {
	m.killer = read_u8(r)
	m.victim = read_u8(r)
	m.weapon = read_u8(r)
	return m, !r.error
}

// One landed hit on the receiving client's own pawn. Unreliable, written into
// the same datagram as that tick's snapshot and BEFORE it, so the receiver
// registers the heading before reconciliation sees the health drop. Loss is
// covered by the client's directionless health-drop fallback.
Damage_Msg :: struct {
	tick:      u32, // server tick the hit landed on
	// World-space yaw degrees from victim toward attacker, same frame as the
	// camera yaw (0 = +X east, counter-clockwise). Rides the yaw quantizer.
	direction: f32,
	amount:    u8,
}

write_damage :: proc(w: ^Writer, m: Damage_Msg) {
	write_u32(w, m.tick)
	write_u16(w, quantize_yaw(m.direction))
	write_u8(w, m.amount)
}

read_damage :: proc(r: ^Reader) -> (m: Damage_Msg, ok: bool) {
	m.tick = read_u32(r)
	m.direction = dequantize_yaw(read_u16(r))
	m.amount = read_u8(r)
	return m, !r.error
}

// ------------------------------------------------------------------- inputs

// The redundant command block: the newest command plus up to INPUT_REDUNDANCY-1
// older ones, oldest first, covering ticks newest_tick-count+1 .. newest_tick.
// The server takes the ones it has not seen; a lost packet costs nothing until
// the redundancy itself is exceeded.
Input_Msg :: struct {
	// Newest snapshot tick the client has received -- the future baseline for
	// delta compression, and a health signal today.
	last_snapshot_tick: u32,
	newest_tick:        u32,
	count:              u8,
	commands:           [INPUT_REDUNDANCY]game.Pawn_Input,
}

write_input :: proc(w: ^Writer, m: Input_Msg) {
	write_u32(w, m.last_snapshot_tick)
	write_u32(w, m.newest_tick)
	count := min(m.count, INPUT_REDUNDANCY)
	write_u8(w, count)
	for i in 0 ..< count {
		write_command(w, m.commands[i])
	}
}

read_input :: proc(r: ^Reader) -> (m: Input_Msg, ok: bool) {
	m.last_snapshot_tick = read_u32(r)
	m.newest_tick = read_u32(r)
	m.count = min(read_u8(r), INPUT_REDUNDANCY)
	for i in 0 ..< m.count {
		m.commands[i] = read_command(r)
	}
	return m, !r.error
}

// 7 bytes per command. The angles go through the quantizers, which is also why
// the client must run its own prediction on the dequantized values.
write_command :: proc(w: ^Writer, c: game.Pawn_Input) {
	write_u16(w, transmute(u16)c.buttons)
	write_u16(w, quantize_yaw(c.yaw))
	write_u16(w, quantize_pitch(c.pitch))
	write_u8(w, u8(c.weapon_slot))
}

read_command :: proc(r: ^Reader) -> (c: game.Pawn_Input) {
	c.buttons = transmute(game.Buttons)read_u16(r)
	c.yaw = dequantize_yaw(read_u16(r))
	c.pitch = dequantize_pitch(read_u16(r))
	c.weapon_slot = i8(read_u8(r))
	return
}

// The exact angles prediction has to use: what the server will read back out
// of what the client is about to send.
wire_angles :: proc(yaw, pitch: f32) -> (f32, f32) {
	return dequantize_yaw(quantize_yaw(yaw)), dequantize_pitch(quantize_pitch(pitch))
}
