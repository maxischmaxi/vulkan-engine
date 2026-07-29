// The client half of the Steam transport: one P2P connection to a server
// addressed by its SteamID, relayed and encrypted by Steam. The wire protocol
// on top is byte-identical to the UDP path -- SNS replaces only the socket;
// the app-level handshake still runs inside the connection once Steam reports
// it open.
package main

import steam "../steamworks"
import "core:log"
import "protocol"

Steam_Net :: struct {
	sns:        ^steam.INetworkingSockets,
	conn:       steam.HSteamNetConnection,
	connecting: bool,
	connected:  bool,
}

steam_net: Steam_Net

@(private = "file")
steam_recv_buf: [protocol.MTU]u8

steam_net_connect :: proc(steamid: u64) {
	// Defensive: a stray previous connection must not leak into a fresh one.
	steam_net_close(false)
	steam_net.sns = steam.NetworkingSockets_SteamAPI()
	identity: steam.SteamNetworkingIdentity
	steam.NetworkingIdentity_SetSteamID64(&identity, steamid)
	when STEAM_REQUIRED {
		// Relay only, mirroring the server: no ICE, no IP exchange.
		opts := [1]steam.SteamNetworkingConfigValue {
			{eValue = .P2P_Transport_ICE_Enable, eDataType = .Int32, i64 = 0},
		}
		steam_net.conn = steam.NetworkingSockets_ConnectP2P(
			steam_net.sns,
			&identity,
			0,
			i32(len(opts)),
			&opts[0],
		)
	} else {
		steam_net.conn = steam.NetworkingSockets_ConnectP2P(steam_net.sns, &identity, 0, 0, nil)
	}
	steam_net.connecting = true
}

// Dispatched from steam_pump. Steam owns the connection's liveness; the
// protocol layer only learns "open" (start the handshake) or "gone".
steam_net_on_status :: proc(cb: ^steam.SteamNetConnectionStatusChangedCallback) {
	if cb.hConn != steam_net.conn || steam_net.conn == 0 do return
	#partial switch cb.info.eState {
	case .Connected:
		steam_net.connecting = false
		steam_net.connected = true
		log.infof("NET: steam route up ({})", cstring(&cb.info.szConnectionDescription[0]))
		net_try_connect_request()

	case .ClosedByPeer, .ProblemDetectedLocally:
		was_connecting := steam_net.connecting
		log.warnf("NET: steam connection lost ({})", cstring(&cb.info.szEndDebug[0]))
		// The deny/disconnect datagram is unreliable, but the server mirrors
		// its reason into the close handshake -- prefer that over a generic
		// message when it is one of ours.
		code := int(cb.info.eEndReason)
		switch {
		case code >= protocol.CLOSE_CODE_DENY_BASE && code < protocol.CLOSE_CODE_DENY_BASE + 100:
			net_fail(deny_text(protocol.Deny_Reason(code - protocol.CLOSE_CODE_DENY_BASE)))
		case code >= protocol.CLOSE_CODE_DISCONNECT_BASE &&
		     code < protocol.CLOSE_CODE_DISCONNECT_BASE + 100:
			net_fail(
				server_disconnect_text(
					protocol.Disconnect_Reason(code - protocol.CLOSE_CODE_DISCONNECT_BASE),
				),
			)
		case:
			net_fail(was_connecting ? "COULD NOT REACH SERVER" : "CONNECTION LOST")
		}
	}
}

// One message per call, copied out so the caller sees a plain datagram and
// the SNS buffer can be released immediately.
steam_net_poll :: proc() -> ([]u8, bool) {
	if steam_net.conn == 0 do return nil, false
	msg: ^steam.SteamNetworkingMessage
	n := steam.NetworkingSockets_ReceiveMessagesOnConnection(
		steam_net.sns,
		steam_net.conn,
		&msg,
		1,
	)
	if n <= 0 do return nil, false
	size := min(int(msg.cbSize), len(steam_recv_buf))
	copy(steam_recv_buf[:size], ([^]u8)(msg.pData)[:size])
	steam.NetworkingMessage_t_Release(msg)
	return steam_recv_buf[:size], true
}

steam_net_send :: proc(data: []u8) {
	if steam_net.conn == 0 do return
	res := steam.NetworkingSockets_SendMessageToConnection(
		steam_net.sns,
		steam_net.conn,
		raw_data(data),
		u32(len(data)),
		steam.nSteamNetworkingSend_UnreliableNoNagle,
		nil,
	)
	if res != .OK {
		// Routine while the route is still forming or tearing down.
		log.debugf("NET: steam send failed ({})", res)
	}
}

steam_net_close :: proc(linger: bool) {
	if steam_net.sns != nil && steam_net.conn != 0 {
		steam.NetworkingSockets_CloseConnection(steam_net.sns, steam_net.conn, 0, nil, linger)
	}
	steam_net = {}
}
