// Server-side Steamworks glue: anonymous game-server login and the manual
// dispatch pump. Everything Steam tells the server arrives on the game-server
// pipe -- not the user pipe -- and is dispatched from here. Dev builds treat
// Steam as optional (UDP keeps working, -insecure skips Steam entirely);
// STEAM_REQUIRED builds refuse to run without it.
package main

import steam "../../steamworks"
import "core:log"
import "core:os"

STEAM_REQUIRED :: #config(STEAM_REQUIRED, false)

// What the Steam backend shows as server version; bump with releases.
STEAM_SERVER_VERSION :: "1.0.0.0"

Steam_Server :: struct {
	active:    bool, // InitEx succeeded, pump is running
	logged_on: bool, // anonymous logon confirmed, listen socket open
	sns:       ^steam.INetworkingSockets,
	listen:    steam.HSteamListenSocket,
	poll:      steam.HSteamNetPollGroup,
}

steam_sv: Steam_Server

steam_server_init :: proc(port: int) {
	when !STEAM_REQUIRED {
		if sv.insecure do return
	}

	err_msg: steam.SteamErrMsg
	res := steam.SteamGameServer_InitEx(
		0,
		u16(port),
		steam.STEAMGAMESERVER_QUERY_PORT_SHARED,
		.Authentication,
		STEAM_SERVER_VERSION,
		&err_msg,
	)
	if res != .OK {
		when STEAM_REQUIRED {
			log.errorf(
				"Steam game server init failed: {} ({})",
				res,
				transmute(cstring)&err_msg[0],
			)
			steam_server_exit(1)
		} else {
			log.warnf("Steam game server unavailable ({}), UDP only", res)
			return
		}
	}

	gs := steam.GameServer()
	steam.GameServer_SetProduct(gs, "dust2")
	steam.GameServer_SetGameDescription(gs, "team deathmatch")
	steam.GameServer_SetModDir(gs, "dust2")
	steam.GameServer_SetDedicatedServer(gs, true)
	steam.GameServer_SetMaxPlayerCount(gs, MAX_CLIENTS)
	// No server browser yet, so no reason to tell the master list we exist.
	steam.GameServer_SetAdvertiseServerActive(gs, false)

	steam.ManualDispatch_Init()
	steam.GameServer_LogOnAnonymous(gs)
	// No InitRelayNetworkAccess here: the global NetworkingUtils accessor is
	// user-API only and fails in a pure game-server process. SDR access starts
	// on its own when the P2P listen socket opens after logon.
	steam_sv.active = true
	log.info("Steam: game server logging on anonymously")
}

steam_server_shutdown :: proc() {
	if !steam_sv.active do return
	steam.SteamGameServer_Shutdown()
	steam_sv = {}
}

// One drain per tick, on the game-server pipe. A callback pumped from the
// wrong pipe never arrives, which looks exactly like an auth timeout -- keep
// every gameserver callback here.
steam_server_pump :: proc() {
	if !steam_sv.active do return
	pipe := steam.SteamGameServer_GetHSteamPipe()
	steam.ManualDispatch_RunFrame(pipe)
	msg: steam.CallbackMsg
	for steam.ManualDispatch_GetNextCallback(pipe, &msg) {
		#partial switch msg.iCallback {
		case .SteamServersConnected:
			steam_sv.logged_on = true
			log.infof(
				"Steam: game server logged on, steamid {} -- clients join with --connect={}",
				steam.SteamGameServer_GetSteamID(),
				steam.SteamGameServer_GetSteamID(),
			)
			steam_net_listen()

		case .SteamServerConnectFailure:
			cb := transmute(^steam.SteamServerConnectFailure)msg.pubParam
			if cb.bStillRetrying {
				log.warnf("Steam: game server logon failed ({}), retrying", cb.eResult)
			} else {
				// Without a logon there is no listen socket; a STEAM_REQUIRED
				// server would sit unreachable forever, so it stops instead.
				log.errorf("Steam: game server logon failed for good ({})", cb.eResult)
				when STEAM_REQUIRED do steam_server_exit(1)
			}

		case .SteamServersDisconnected:
			steam_sv.logged_on = false
			log.warn("Steam: game server lost the Steam connection")

		case .SteamNetConnectionStatusChangedCallback:
			steam_net_on_status(
				transmute(^steam.SteamNetConnectionStatusChangedCallback)msg.pubParam,
			)

		case .ValidateAuthTicketResponse:
			steam_on_validate_ticket(transmute(^steam.ValidateAuthTicketResponse)msg.pubParam)
		}
		steam.ManualDispatch_FreeLastCallback(pipe)
	}
}

// Compiled in every build so the core:os import is never conditionally dead,
// which -vet-unused would reject; only STEAM_REQUIRED paths call it.
@(private = "file")
steam_server_exit :: proc(code: int) {
	os.exit(code)
}
