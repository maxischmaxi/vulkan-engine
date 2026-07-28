package main

import "../game"
import "../protocol"
import "core:log"
import "core:math/rand"
import "core:net"
import "core:time"

// Who is connected, and what they are allowed to mean. Every datagram lands
// here first: unconnected traffic may only ever become a handshake, connected
// traffic is validated by its session before a single byte of it reaches the
// game. validate_command below is the one gate all gameplay input passes --
// the place future anti-cheat checks accumulate.

MAX_CLIENTS :: 4

// Commands buffered per client: covers the 8-deep redundancy plus jitter.
INPUT_BUFFER :: 64

// If the client starves longer than this, it stops moving instead of ghosting
// on its last held keys.
MAX_STARVE_TICKS :: 8

// More than this many commands waiting means the client's clock runs ahead;
// skipping forward trades a one-off correction for permanent added latency.
MAX_INPUT_BACKLOG :: 6

Client_State :: enum u8 {
	Empty,
	Connected, // handshake done, sitting in the menu / team select
	In_Game, // joined a match, owns a pawn
}

Client_Slot :: struct {
	state:           Client_State,
	endpoint:        net.Endpoint,
	conn:            protocol.Connection,
	client_salt:     u32,
	server_salt:     u32,
	last_recv:       time.Tick,
	pawn_id:         int,
	name:            [protocol.MAX_NAME]u8,
	name_len:        u8,
	team:            game.Team,
	// Debug grants, kept on the slot so they survive respawns and rematches.
	debug_god:       bool,
	debug_infinite:  bool,
	// The buy menu's choice, kept on the slot for the same reason: the next
	// spawn reads it, whenever that is.
	loadout:         game.Loadout,
	// The newest snapshot the client confirms holding: the delta baseline.
	// Distinct from command_base, which keeps each command's first-delivery
	// value for the rewind; this one always advances to the newest.
	acked_snapshot:  u32,
	// input stream, keyed by client tick
	commands:        [INPUT_BUFFER]game.Pawn_Input,
	command_ticks:   [INPUT_BUFFER]u32,
	// Per command: the newest snapshot the client had when it was made -- the
	// anchor lag compensation rewinds from.
	command_base:    [INPUT_BUFFER]u32,
	newest_cmd_tick: u32,
	consumed_tick:   u32, // last client tick applied to the sim
	have_consumed:   bool,
	last_cmd:        game.Pawn_Input,
	last_base:       u32,
	starve_ticks:    int,
}

clients: [MAX_CLIENTS]Client_Slot

recv_buf: [protocol.MTU]u8

receive_packets :: proc() {
	for {
		n, ep, err := net.recv_udp(sv.socket, recv_buf[:])
		if err == .Would_Block do break
		if err != nil {
			// Transient network errors are logged and survived; a dead socket
			// would spin here, so anything persistent shows up loudly.
			log.warnf("Server: recv error {}", err)
			break
		}
		if n < protocol.HEADER_SIZE do continue
		handle_packet(ep, recv_buf[:n])
	}
}

@(private = "file")
handle_packet :: proc(ep: net.Endpoint, data: []u8) {
	// The session field sits at a fixed offset; zero marks handshake traffic,
	// which is the only thing an unknown endpoint may say to us.
	r := protocol.reader(data)
	magic := protocol.read_u16(&r)
	version := protocol.read_u8(&r)
	_ = protocol.read_u8(&r) // flags
	session := protocol.read_u32(&r)
	if magic != protocol.PROTOCOL_MAGIC do return

	if session == 0 {
		handle_unconnected(ep, version, data)
		return
	}

	slot := find_client(ep)
	if slot == nil do return

	pr, ok := protocol.connection_read(&slot.conn, data)
	if !ok do return
	slot.last_recv = time.tick_now()

	// reliable control messages, in order, exactly once
	for i in 0 ..< slot.conn.incoming_count {
		msg := &slot.conn.incoming[i]
		payload := protocol.reader(msg.payload[:msg.size])
		#partial switch msg.msg_id {
		case .Join:
			if join, jok := protocol.read_join(&payload); jok {
				handle_join(slot, join.team)
			}
		case .Debug_Flags:
			if flags, fok := protocol.read_debug_flags(&payload); fok {
				apply_debug_flags(slot, flags)
			}
		case .Loadout:
			if m, lok := protocol.read_loadout(&payload); lok {
				handle_loadout(slot, m)
			}
		case:
			log.warnf("Server: unexpected reliable message {}", msg.msg_id)
		}
	}

	// unreliable messages to the end of the datagram
	for !pr.error && pr.off < len(pr.buf) {
		id := protocol.Msg_Id(protocol.read_u8(&pr))
		#partial switch id {
		case .Input:
			if msg, mok := protocol.read_input(&pr); mok {
				store_input(slot, msg)
			}
		case .Keepalive:
		// the header already did its job
		case .Disconnect:
			if _, mok := protocol.read_disconnect(&pr); mok {
				log.infof("Server: client {} left", client_index(slot))
				drop_client(slot)
				return
			}
		case:
			// Unknown unreliable messages have no length prefix, so the rest
			// of the datagram is unreadable. Drop it, keep the connection.
			return
		}
	}
}

@(private = "file")
handle_unconnected :: proc(ep: net.Endpoint, version: u8, data: []u8) {
	// Re-parse as a full packet through a throwaway session-0 connection: the
	// handshake rides the same framing as everything else.
	scratch: protocol.Connection
	protocol.connection_init(&scratch, 0)
	pr, ok := protocol.connection_read(&scratch, data)
	if !ok {
		if version != protocol.PROTOCOL_VERSION {
			send_deny(ep, .Bad_Version)
		}
		return
	}

	if protocol.Msg_Id(protocol.read_u8(&pr)) != .Connect_Request do return
	request, rok := protocol.read_connect_request(&pr)
	if !rok do return

	// A duplicate request from a known endpoint gets the same accept again --
	// the first one may have been lost, and the handshake must be idempotent.
	if slot := find_client(ep); slot != nil {
		if slot.client_salt == request.client_salt {
			send_accept(slot)
		}
		return
	}

	slot := find_free_slot()
	if slot == nil {
		send_deny(ep, .Full)
		return
	}

	index := client_index(slot)
	slot^ = {}
	// The command ring tests "does this slot hold tick N" by equality; a fresh
	// zeroed ring would falsely claim to hold tick 0.
	for &t in slot.command_ticks do t = max(u32)
	slot.state = .Connected
	slot.endpoint = ep
	slot.client_salt = request.client_salt
	slot.server_salt = rand.uint32()
	slot.name = request.name
	slot.name_len = request.name_len
	slot.pawn_id = index
	slot.last_recv = time.tick_now()
	protocol.connection_init(&slot.conn, request.client_salt ~ slot.server_salt)

	name := string(slot.name[:slot.name_len])
	log.infof("Server: client {} connected ({}) from {}", index, name, net.endpoint_to_string(ep))
	send_accept(slot)
}

@(private = "file")
send_accept :: proc(slot: ^Client_Slot) {
	// Handshake packets carry session 0: the client cannot know the real
	// session before this very message arrives.
	scratch: protocol.Connection
	protocol.connection_init(&scratch, 0)

	buf: [128]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&scratch, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Connect_Accept))
	protocol.write_connect_accept(
		&w,
		{
			server_salt = slot.server_salt,
			server_tick = sv.tick,
			pawn_id = u8(slot.pawn_id),
			tick_rate = game.TICK_RATE,
			phase = match.phase,
		},
	)
	send_to(slot.endpoint, w.buf[:w.off])
}

@(private = "file")
send_deny :: proc(ep: net.Endpoint, reason: protocol.Deny_Reason) {
	scratch: protocol.Connection
	protocol.connection_init(&scratch, 0)

	buf: [64]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&scratch, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Connect_Deny))
	protocol.write_connect_deny(&w, {reason = reason})
	send_to(ep, w.buf[:w.off])
}

send_to :: proc(ep: net.Endpoint, data: []u8) {
	if _, err := net.send_udp(sv.socket, data, ep); err != nil {
		log.warnf("Server: send error {}", err)
	}
}

find_client :: proc(ep: net.Endpoint) -> ^Client_Slot {
	for &slot in clients {
		if slot.state == .Empty do continue
		if slot.endpoint == ep do return &slot
	}
	return nil
}

@(private = "file")
find_free_slot :: proc() -> ^Client_Slot {
	for &slot in clients {
		if slot.state == .Empty do return &slot
	}
	return nil
}

client_index :: proc(slot: ^Client_Slot) -> int {
	for &s, i in clients {
		if &s == slot do return i
	}
	return -1
}

update_clients :: proc() {
	for &slot in clients {
		if slot.state == .Empty do continue
		if time.duration_seconds(time.tick_since(slot.last_recv)) > protocol.TIMEOUT_SECONDS {
			log.infof("Server: client {} timed out", client_index(&slot))
			drop_client(&slot)
		}
	}
}

drop_client :: proc(slot: ^Client_Slot) {
	was_in_game := slot.state == .In_Game
	sv.gs.pawns[slot.pawn_id] = {}
	slot^ = {}
	if was_in_game {
		match_human_left()
	}
}

// ------------------------------------------------------------------- inputs

// The one gate between the wire and the simulation. Everything that would let
// a modified client cheat through its inputs gets clamped here.
@(private = "file")
validate_command :: proc(cmd: ^game.Pawn_Input) {
	cmd.pitch = clamp(cmd.pitch, -89, 89)
	if cmd.weapon_slot < -1 || int(cmd.weapon_slot) >= game.WEAPON_SLOTS {
		cmd.weapon_slot = -1
	}
	// Noclip is a debug affordance; the server simply never grants it, and a
	// pawn with the flag off ignores whatever the client wishes it meant.
}

@(private = "file")
store_input :: proc(slot: ^Client_Slot, msg: protocol.Input_Msg) {
	// Future ticks beyond a small margin are a modified client speeding up
	// its clock; the margin covers honest run-ahead.
	if msg.newest_tick > sv.tick + 64 do return

	// The rewind anchor; a claimed-future snapshot is a lie, clamp it.
	base := min(msg.last_snapshot_tick, sv.tick)

	// An honest ack names a tick already sent, i.e. strictly older than the
	// tick being simulated right now.
	if base > slot.acked_snapshot && base < sv.tick {
		slot.acked_snapshot = base
	}

	count := int(msg.count)
	for i in 0 ..< count {
		tick := msg.newest_tick - u32(count - 1 - i)
		if slot.have_consumed && !protocol_tick_newer(tick, slot.consumed_tick) do continue

		// First delivery only: redundant re-sends carry identical commands but
		// a newer snapshot base, which would skew the rewind toward now.
		idx := tick % INPUT_BUFFER
		if slot.command_ticks[idx] == tick do continue

		cmd := msg.commands[i]
		validate_command(&cmd)
		slot.commands[idx] = cmd
		slot.command_ticks[idx] = tick
		slot.command_base[idx] = base
	}
	if msg.newest_tick > slot.newest_cmd_tick {
		slot.newest_cmd_tick = msg.newest_tick
	}
}

// u32 tick comparison; ticks never wrap in a real session (2^32 ticks is two
// years), so plain compare is fine -- named for the intent.
@(private = "file")
protocol_tick_newer :: proc(a, b: u32) -> bool {
	return a > b
}

// One command per server tick, in client-tick order, plus the snapshot base
// the command was made against (for lag compensation). Loss inside the
// redundancy window costs nothing; a longer gap repeats the last command with
// its edge bits stripped, and a real silence parks the pawn.
consume_command :: proc(slot: ^Client_Slot) -> (game.Pawn_Input, u32) {
	next := slot.have_consumed ? slot.consumed_tick + 1 : slot.newest_cmd_tick

	// A backlog means the client ticks ahead of us; jump forward so its input
	// lag stays bounded.
	if slot.have_consumed && slot.newest_cmd_tick > next + MAX_INPUT_BACKLOG {
		next = slot.newest_cmd_tick - 2
	}

	if slot.command_ticks[next % INPUT_BUFFER] == next && next <= slot.newest_cmd_tick {
		slot.consumed_tick = next
		slot.have_consumed = true
		slot.last_cmd = slot.commands[next % INPUT_BUFFER]
		slot.last_base = slot.command_base[next % INPUT_BUFFER]
		slot.starve_ticks = 0
		return slot.last_cmd, slot.last_base
	}

	// Nothing for this tick: scan forward to the oldest stored command after
	// it (a loss burst ate the gap).
	if slot.have_consumed {
		for tick := next + 1; tick <= slot.newest_cmd_tick; tick += 1 {
			if slot.command_ticks[tick % INPUT_BUFFER] != tick do continue
			slot.consumed_tick = tick
			slot.last_cmd = slot.commands[tick % INPUT_BUFFER]
			slot.last_base = slot.command_base[tick % INPUT_BUFFER]
			slot.starve_ticks = 0
			return slot.last_cmd, slot.last_base
		}
	}

	// Starved: ghost on the held keys briefly, then stand still. Edge bits
	// must not repeat -- a buffered jump re-firing every starved tick would
	// pogo the pawn. A held trigger keeps firing here, so the stale base
	// still matters; the rewind clamp bounds how stale it can get.
	slot.starve_ticks += 1
	cmd := slot.last_cmd
	cmd.buttons -= {.Jump_Pressed, .Fire_Pressed}
	if slot.starve_ticks > MAX_STARVE_TICKS {
		cmd.buttons = {}
	}
	return cmd, slot.last_base
}
