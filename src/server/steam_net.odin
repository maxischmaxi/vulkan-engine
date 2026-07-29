// The Steam transport: a P2P listen socket addressed by the server's SteamID,
// every connection relayed (or in dev, NAT-punched) by Steam and encrypted by
// it. Datagrams that arrive here are byte-identical to the UDP ones; the
// protocol layer never learns which transport carried them.
package main

import steam "../../steamworks"
import "../protocol"
import "core:log"
import "core:time"

// Accepted connections that have not claimed a slot yet. Bounded so a flood
// of silent connections cannot pile up relay sessions: when the table is
// full, new connections are rejected outright, and entries that never send a
// Connect_Request expire.
UNCLAIMED_MAX :: 8
UNCLAIMED_TIMEOUT_SECONDS :: 10.0

Unclaimed_Conn :: struct {
	conn:  steam.HSteamNetConnection, // 0 marks a free entry
	since: time.Tick,
}

@(private = "file")
unclaimed: [UNCLAIMED_MAX]Unclaimed_Conn

// Opened once the anonymous logon confirms, because the listen socket is
// addressed by the SteamID the logon establishes.
steam_net_listen :: proc() {
	if steam_sv.sns != nil do return
	steam_sv.sns = steam.GameServerNetworkingSockets_SteamAPI()
	when STEAM_REQUIRED {
		// Relay only: with ICE disabled no direct route is ever negotiated,
		// so neither side learns the other's IP.
		opts := [1]steam.SteamNetworkingConfigValue {
			{eValue = .P2P_Transport_ICE_Enable, eDataType = .Int32, i64 = 0},
		}
		steam_sv.listen = steam.NetworkingSockets_CreateListenSocketP2P(
			steam_sv.sns,
			0,
			i32(len(opts)),
			&opts[0],
		)
	} else {
		steam_sv.listen = steam.NetworkingSockets_CreateListenSocketP2P(steam_sv.sns, 0, 0, nil)
	}
	steam_sv.poll = steam.NetworkingSockets_CreatePollGroup(steam_sv.sns)
	log.info("Steam: P2P listen socket open on virtual port 0")
}

steam_net_on_status :: proc(cb: ^steam.SteamNetConnectionStatusChangedCallback) {
	if steam_sv.sns == nil do return
	#partial switch cb.info.eState {
	case .Connecting:
		// The connection already carries an authenticated SteamID; the
		// app-level handshake decides whether it may become a client. Accept
		// only while there is room to track it.
		if cb.info.hListenSocket != steam_sv.listen do return
		entry := unclaimed_free_entry()
		if entry == nil {
			log.warn("Server: rejecting steam connection, unclaimed table full")
			steam.NetworkingSockets_CloseConnection(steam_sv.sns, cb.hConn, 0, nil, false)
			return
		}
		if steam.NetworkingSockets_AcceptConnection(steam_sv.sns, cb.hConn) != .OK {
			steam.NetworkingSockets_CloseConnection(steam_sv.sns, cb.hConn, 0, nil, false)
			return
		}
		steam.NetworkingSockets_SetConnectionPollGroup(steam_sv.sns, cb.hConn, steam_sv.poll)
		entry^ = {
			conn  = cb.hConn,
			since = time.tick_now(),
		}

	case .ClosedByPeer, .ProblemDetectedLocally:
		if slot := find_client_by_conn(cb.hConn); slot != nil {
			log.infof(
				"Server: client {} steam connection closed ({})",
				client_index(slot),
				cstring(&cb.info.szEndDebug[0]),
			)
			drop_client(slot)
		} else {
			// Never became a client; just free the connection handle.
			steam_net_close_conn(cb.hConn, false)
		}
	}
}

// Called when a connection turns into a slot: it is accounted for there now.
steam_net_claim_conn :: proc(conn: steam.HSteamNetConnection) {
	for &entry in unclaimed {
		if entry.conn == conn do entry = {}
	}
}

// Connections that sat in the accept table without ever claiming a slot.
// Driven from update_clients so it shares the tick cadence.
steam_expire_unclaimed :: proc() {
	if steam_sv.sns == nil do return
	for &entry in unclaimed {
		if entry.conn == 0 do continue
		if time.duration_seconds(time.tick_since(entry.since)) > UNCLAIMED_TIMEOUT_SECONDS {
			log.info("Server: expiring unclaimed steam connection")
			steam_net_close_conn(entry.conn, false)
		}
	}
}

@(private = "file")
unclaimed_free_entry :: proc() -> ^Unclaimed_Conn {
	for &entry in unclaimed {
		if entry.conn == 0 do return &entry
	}
	return nil
}

steam_receive_packets :: proc() {
	if steam_sv.sns == nil do return
	msgs: [64]^steam.SteamNetworkingMessage
	for {
		n := steam.NetworkingSockets_ReceiveMessagesOnPollGroup(
			steam_sv.sns,
			steam_sv.poll,
			&msgs[0],
			i32(len(msgs)),
		)
		if n <= 0 do break
		for i in 0 ..< int(n) {
			msg := msgs[i]
			data := ([^]u8)(msg.pData)[:msg.cbSize]
			if len(data) >= protocol.HEADER_SIZE {
				peer := Peer {
					kind     = .Steam,
					conn     = msg.conn,
					steam_id = steam.NetworkingIdentity_GetSteamID64(&msg.identityPeer),
				}
				handle_packet(peer, data)
			}
			steam.NetworkingMessage_t_Release(msg)
		}
		if int(n) < len(msgs) do break
	}
}

steam_send :: proc(conn: steam.HSteamNetConnection, data: []u8) {
	if steam_sv.sns == nil do return
	res := steam.NetworkingSockets_SendMessageToConnection(
		steam_sv.sns,
		conn,
		raw_data(data),
		u32(len(data)),
		steam.nSteamNetworkingSend_UnreliableNoNagle,
		nil,
	)
	if res != .OK {
		// A dying connection rejects sends until its status callback lands;
		// that is routine, not an error worth a warning per packet.
		log.debugf("Server: steam send to {} failed ({})", conn, res)
	}
}

steam_net_close_conn :: proc(conn: steam.HSteamNetConnection, linger: bool) {
	if steam_sv.sns == nil do return
	steam.NetworkingSockets_CloseConnection(steam_sv.sns, conn, 0, nil, linger)
	steam_net_claim_conn(conn)
}

// Close carrying an app reason (protocol.CLOSE_CODE_*): the close handshake
// is what reliably tells the peer why, the deny/disconnect datagram is only
// the fast path.
steam_net_close_reason :: proc(conn: steam.HSteamNetConnection, code: i32) {
	if steam_sv.sns == nil || conn == 0 do return
	steam.NetworkingSockets_CloseConnection(steam_sv.sns, conn, code, nil, true)
	steam_net_claim_conn(conn)
}
