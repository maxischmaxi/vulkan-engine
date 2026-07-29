package main

import "../game"
import "../protocol"
import "core:log"
import "core:math/rand"
import "core:time"
import steam "../../steamworks"

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
	// Steam peer whose ticket is with the Steam backend; the accept waits for
	// the verdict. Nothing but handshake retries may arrive in this state.
	Authenticating,
	Connected, // handshake done, sitting in the menu / team select
	In_Game, // joined a match, owns a pawn
}

// How long a ticket may sit with Steam before the connect is refused. The
// client's steam connect budget (15 s) comfortably covers it.
AUTH_TIMEOUT_SECONDS :: 10.0

Client_Slot :: struct {
	state:              Client_State,
	peer:               Peer,
	conn:               protocol.Connection,
	client_salt:        u32,
	server_salt:        u32,
	last_recv:          time.Tick,
	auth_start:         time.Tick, // .Authenticating: when the ticket went to Steam
	pawn_id:            int,
	name:               [protocol.MAX_NAME]u8,
	name_len:           u8,
	team:               game.Team,
	// Debug grants, kept on the slot so they survive respawns and rematches.
	debug_god:          bool,
	debug_infinite:     bool,
	// On the practice range: connected, simulating locally, owning no pawn.
	// Recorded so future matchmaking can offer this client a game; today the
	// server does nothing else with it.
	practice:           bool,
	// The buy menu's choice, kept on the slot for the same reason: the next
	// spawn reads it, whenever that is.
	loadout:            game.Loadout,
	// The newest snapshot the client confirms holding: the delta baseline.
	// Distinct from command_base, which keeps each command's first-delivery
	// value for the rewind; this one always advances to the newest.
	acked_snapshot:     u32,
	// input stream, keyed by client tick
	commands:           [INPUT_BUFFER]game.Pawn_Input,
	command_ticks:      [INPUT_BUFFER]u32,
	// Per command: the newest snapshot the client had when it was made -- the
	// anchor lag compensation rewinds from.
	command_base:       [INPUT_BUFFER]u32,
	newest_cmd_tick:    u32,
	consumed_tick:      u32, // last client tick applied to the sim
	have_consumed:      bool,
	last_cmd:           game.Pawn_Input,
	last_base:          u32,
	starve_ticks:       int,
	// Anti-cheat groundwork. The client we ship strips the trigger off the
	// wire wherever the rules refuse it, so a count here did not come from
	// that client -- it is the signal, not the enforcement.
	fire_denied:        int,
	fire_denied_logged: bool,
	// Same groundwork, richer stream: what the aim did around every trigger
	// pull (aim_telemetry.odin). Zeroed with the slot on connect.
	aim:                Aim_Telemetry,
}

clients: [MAX_CLIENTS]Client_Slot

// Both transports feed this: udp.odin's drain and steam_net.odin's poll group.
handle_packet :: proc(peer: Peer, data: []u8) {
	// The session field sits at a fixed offset; zero marks handshake traffic,
	// which is the only thing an unknown endpoint may say to us.
	r := protocol.reader(data)
	magic := protocol.read_u16(&r)
	version := protocol.read_u8(&r)
	_ = protocol.read_u8(&r) // flags
	session := protocol.read_u32(&r)
	if magic != protocol.PROTOCOL_MAGIC do return

	if session == 0 {
		handle_unconnected(peer, version, data)
		return
	}

	slot := find_client(peer)
	if slot == nil do return

	// Until the ticket verdict is in, the only currency is handshake retries
	// (session 0, handled above). Everything else -- Join, Input, Loadout --
	// would let an unvalidated account act.
	if slot.state == .Authenticating do return

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
		case .Practice:
			if m, pok := protocol.read_practice(&payload); pok {
				handle_practice(slot, m)
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
handle_unconnected :: proc(peer: Peer, version: u8, data: []u8) {
	// Re-parse as a full packet through a throwaway session-0 connection: the
	// handshake rides the same framing as everything else.
	scratch: protocol.Connection
	protocol.connection_init(&scratch, 0)
	pr, ok := protocol.connection_read(&scratch, data)
	if !ok {
		if version != protocol.PROTOCOL_VERSION {
			send_deny(peer, .Bad_Version)
		}
		return
	}

	if protocol.Msg_Id(protocol.read_u8(&pr)) != .Connect_Request do return
	request, rok := protocol.read_connect_request(&pr)
	if !rok do return

	// A duplicate request from a known peer gets the same accept again --
	// the first one may have been lost, and the handshake must be idempotent.
	if slot := find_client(peer); slot != nil {
		if slot.client_salt == request.client_salt {
			// While Steam is still judging the ticket there is no accept to
			// repeat; the retry only proves the peer is alive.
			if slot.state == .Authenticating {
				slot.last_recv = time.tick_now()
			} else {
				send_accept(slot)
			}
		}
		return
	}

	if peer.kind == .Steam {
		// The transport already authenticated the SteamID; the ticket is the
		// ownership/ban check on top. Real tickets run ~234 bytes -- anything
		// shorter is junk and must not get as far as evicting a slot.
		if request.ticket_len < 64 {
			deny_and_close(peer, .Bad_Ticket)
			return
		}
		// One account, one slot. A reconnect after a crash arrives while the
		// old slot still lingers, so the old one yields -- but only the old
		// one this packet: the fresh slot is built by the client's next
		// retry, one tick later, so the EndAuthSession here and any stale
		// ValidateAuthTicketResponse drain before the new BeginAuthSession.
		if old := find_client_by_steam_id(peer.steam_id); old != nil {
			log.infof(
				"Server: steamid {} reconnected, dropping old slot {}",
				peer.steam_id,
				client_index(old),
			)
			drop_client(old)
			return
		}
	}

	slot := find_free_slot()
	if slot == nil {
		deny_and_close(peer, .Full)
		return
	}

	index := client_index(slot)
	slot^ = {}
	// The command ring tests "does this slot hold tick N" by equality; a fresh
	// zeroed ring would falsely claim to hold tick 0.
	for &t in slot.command_ticks do t = max(u32)
	slot.peer = peer
	slot.client_salt = request.client_salt
	slot.server_salt = rand.uint32()
	slot.name = request.name
	slot.name_len = request.name_len
	slot.pawn_id = index
	slot.last_recv = time.tick_now()
	protocol.connection_init(&slot.conn, request.client_salt ~ slot.server_salt)

	name := string(slot.name[:slot.name_len])
	if peer.kind == .Steam {
		// The accept waits for Steam's verdict on the ticket; the immediate
		// result only catches tickets that are malformed on their face.
		slot.state = .Authenticating
		slot.auth_start = time.tick_now()
		res := steam.GameServer_BeginAuthSession(
			steam.GameServer(),
			&request.ticket[0],
			i32(request.ticket_len),
			steam.CSteamID(peer.steam_id),
		)
		if res != .OK {
			log.warnf("Server: BeginAuthSession for {} refused ({})", peer.steam_id, res)
			slot^ = {}
			deny_and_close(peer, .Bad_Ticket)
			return
		}
		steam_net_claim_conn(peer.conn)
		log.infof(
			"Server: client {} authenticating ({}) from {}",
			index,
			name,
			peer_desc(peer),
		)
	} else {
		slot.state = .Connected
		log.infof("Server: client {} connected ({}) from {}", index, name, peer_desc(peer))
		send_accept(slot)
	}
}

// Steam's verdict on a ticket, pumped from the game-server pipe. Arrives once
// during the handshake, and again at any time when the session dies under a
// connected client (logout, ban, cancelled ticket).
steam_on_validate_ticket :: proc(cb: ^steam.ValidateAuthTicketResponse) {
	slot := find_client_by_steam_id(u64(cb.SteamID))
	if slot == nil do return

	if slot.state == .Authenticating {
		if cb.eAuthSessionResponse == .OK {
			slot.state = .Connected
			log.infof(
				"Server: client {} authenticated (owner {})",
				client_index(slot),
				u64(cb.OwnerSteamID),
			)
			send_accept(slot)
		} else {
			log.warnf(
				"Server: client {} ticket rejected ({})",
				client_index(slot),
				cb.eAuthSessionResponse,
			)
			reason := deny_reason_for(cb.eAuthSessionResponse)
			send_deny(slot.peer, reason)
			steam_net_close_reason(slot.peer.conn, deny_close_code(reason))
			drop_client(slot)
		}
		return
	}

	// Mid-session revocation. The pawn goes; the account stays bannable.
	if cb.eAuthSessionResponse != .OK {
		log.warnf(
			"Server: client {} auth revoked ({})",
			client_index(slot),
			cb.eAuthSessionResponse,
		)
		// The datagram is best effort; the close reason rides the reliable
		// close handshake and is what the client actually acts on.
		send_server_disconnect(slot, .Auth_Revoked)
		steam_net_close_reason(slot.peer.conn, disconnect_close_code(.Auth_Revoked))
		drop_client(slot)
	}
}

// Deny a peer that owns no slot, then free its transport state. Steam
// connections carry the reason in the close handshake too, because the deny
// datagram itself is unreliable.
@(private = "file")
deny_and_close :: proc(peer: Peer, reason: protocol.Deny_Reason) {
	send_deny(peer, reason)
	if peer.kind == .Steam {
		steam_net_close_reason(peer.conn, deny_close_code(reason))
	}
}

@(private = "file")
deny_close_code :: proc(reason: protocol.Deny_Reason) -> i32 {
	return protocol.CLOSE_CODE_DENY_BASE + i32(reason)
}

@(private = "file")
disconnect_close_code :: proc(reason: protocol.Disconnect_Reason) -> i32 {
	return protocol.CLOSE_CODE_DISCONNECT_BASE + i32(reason)
}

@(private = "file")
deny_reason_for :: proc(r: steam.EAuthSessionResponse) -> protocol.Deny_Reason {
	// NoLicenseOrExpired already covers ownership, so there is no separate
	// UserHasLicenseForApp round trip.
	#partial switch r {
	case .NoLicenseOrExpired:
		return .No_License
	case .VACBanned, .PublisherIssuedBan:
		return .Banned
	}
	return .Bad_Ticket
}

@(private = "file")
send_server_disconnect :: proc(slot: ^Client_Slot, reason: protocol.Disconnect_Reason) {
	buf: [64]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&slot.conn, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Server_Disconnect))
	protocol.write_disconnect(&w, {reason = reason})
	send_to(slot.peer, w.buf[:w.off])
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
	send_to(slot.peer, w.buf[:w.off])
}

@(private = "file")
send_deny :: proc(peer: Peer, reason: protocol.Deny_Reason) {
	scratch: protocol.Connection
	protocol.connection_init(&scratch, 0)

	buf: [64]u8
	w := protocol.writer(buf[:])
	protocol.connection_begin_packet(&scratch, &w)
	protocol.write_u8(&w, u8(protocol.Msg_Id.Connect_Deny))
	protocol.write_connect_deny(&w, {reason = reason})
	send_to(peer, w.buf[:w.off])
}

send_to :: proc(peer: Peer, data: []u8) {
	switch peer.kind {
	case .Udp:
		udp_send_to(peer.ep, data)
	case .Steam:
		steam_send(peer.conn, data)
	}
}

find_client :: proc(peer: Peer) -> ^Client_Slot {
	for &slot in clients {
		if slot.state == .Empty do continue
		if peer_equal(slot.peer, peer) do return &slot
	}
	return nil
}

find_client_by_conn :: proc(conn: steam.HSteamNetConnection) -> ^Client_Slot {
	for &slot in clients {
		if slot.state == .Empty do continue
		if slot.peer.kind == .Steam && slot.peer.conn == conn do return &slot
	}
	return nil
}

find_client_by_steam_id :: proc(steam_id: u64) -> ^Client_Slot {
	for &slot in clients {
		if slot.state == .Empty do continue
		if slot.peer.kind == .Steam && slot.peer.steam_id == steam_id do return &slot
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
		// An authenticating slot answers to exactly one deadline: Steam's
		// verdict. The generic last_recv timeout would fire first (5 < 10)
		// and silently eat the deny.
		if slot.state == .Authenticating {
			if time.duration_seconds(time.tick_since(slot.auth_start)) > AUTH_TIMEOUT_SECONDS {
				log.warnf("Server: client {} auth timed out", client_index(&slot))
				send_deny(slot.peer, .Auth_Timeout)
				steam_net_close_reason(slot.peer.conn, deny_close_code(.Auth_Timeout))
				drop_client(&slot)
			}
			continue
		}
		if time.duration_seconds(time.tick_since(slot.last_recv)) > protocol.TIMEOUT_SECONDS {
			log.infof("Server: client {} timed out", client_index(&slot))
			drop_client(&slot)
		}
	}
	steam_expire_unclaimed()
}

drop_client :: proc(slot: ^Client_Slot) {
	was_in_game := slot.state == .In_Game
	if slot.peer.kind == .Steam {
		if steam_sv.active {
			steam.GameServer_EndAuthSession(steam.GameServer(), steam.CSteamID(slot.peer.steam_id))
		}
		// Linger so a queued Server_Disconnect still flushes before the
		// connection dies.
		steam_net_close_conn(slot.peer.conn, true)
	}
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
