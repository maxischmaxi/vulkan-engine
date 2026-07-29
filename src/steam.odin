// Client-side Steamworks glue: init/shutdown, the manual-dispatch callback
// pump, and the sanitised persona name the menu and the connect handshake use.
// Dev builds run without Steam -- a failed init leaves the state zeroed and
// every caller degrades to its local fallback. STEAM_REQUIRED builds make
// Steam mandatory and relaunch through the Steam client when started directly.
package main

import steam "../steamworks"
import "core:log"
import "core:os"
import "core:strings"
import "protocol"

STEAM_REQUIRED :: #config(STEAM_REQUIRED, false)
STEAM_APP_ID :: #config(STEAM_APP_ID, 480)

Steam_State :: struct {
	initialized:   bool,
	steam_id:      u64,
	persona:       [protocol.MAX_NAME]u8,
	persona_len:   int,
	ticket:        [protocol.MAX_TICKET]u8,
	ticket_len:    u32,
	ticket_handle: steam.HAuthTicket,
	ticket_ready:  bool,
}

steam_state: Steam_State

steam_available :: proc() -> bool {
	return steam_state.initialized
}

steam_init :: proc() {
	// The benchmark is a local measurement: Steam would add its pump and the
	// overlay to the numbers, and a release binary would even relaunch itself
	// through Steam before measuring anything.
	if cli.bench > 0 do return

	when STEAM_REQUIRED {
		if steam.RestartAppIfNecessary(STEAM_APP_ID) {
			log.info("Relaunching through Steam")
			steam_exit(0)
		}
	} else {
		if cli.no_steam do return
	}

	err_msg: steam.SteamErrMsg
	if err := steam.InitFlat(&err_msg); err != .OK {
		when STEAM_REQUIRED {
			log.errorf("Steam init failed: {} ({})", err, transmute(cstring)&err_msg[0])
			steam_exit(1)
		} else {
			log.warnf("Steam unavailable ({}), running without it", err)
			return
		}
	}

	steam.ManualDispatch_Init()
	steam_state.initialized = true
	steam_state.steam_id = u64(steam.User_GetSteamID(steam.User()))
	sanitize_persona(string(steam.Friends_GetPersonaName(steam.Friends())))
	// Relay access takes a few seconds to come up; starting it at boot hides
	// that latency behind the menu instead of the first connect.
	steam.NetworkingUtils_InitRelayNetworkAccess(steam.NetworkingUtils_SteamAPI())
	log.infof("Steam: logged in as {} ({})", steam_persona(), steam_state.steam_id)
}

steam_shutdown :: proc() {
	if !steam_state.initialized do return
	steam.Shutdown()
	steam_state.initialized = false
}

// One drain per frame. Everything Steam tells us arrives here; features hook
// their case into the switch rather than owning a pump of their own.
steam_pump :: proc() {
	if !steam_state.initialized do return
	pipe := steam.GetHSteamPipe()
	steam.ManualDispatch_RunFrame(pipe)
	msg: steam.CallbackMsg
	for steam.ManualDispatch_GetNextCallback(pipe, &msg) {
		#partial switch msg.iCallback {
		case .GetAuthSessionTicketResponse:
			response := transmute(^steam.GetAuthSessionTicketResponse)msg.pubParam
			if response.hAuthTicket == steam_state.ticket_handle {
				// A failed response still unblocks the handshake: the server is
				// the arbiter, and its Bad_Ticket deny beats a silent stall.
				if response.eResult != .OK {
					log.warnf("Steam: auth ticket response {}", response.eResult)
				}
				steam_state.ticket_ready = true
				net_try_connect_request()
			}

		case .SteamNetConnectionStatusChangedCallback:
			steam_net_on_status(
				transmute(^steam.SteamNetConnectionStatusChangedCallback)msg.pubParam,
			)
		}
		steam.ManualDispatch_FreeLastCallback(pipe)
	}
}

// Fetch a ticket addressed to the server about to be joined. The buffer must
// stay put until the ticket is cancelled -- it lives in steam_state for that.
steam_request_ticket :: proc(server_id: u64) {
	if !steam_state.initialized do return
	steam_cancel_ticket()
	identity: steam.SteamNetworkingIdentity
	steam.NetworkingIdentity_SetSteamID64(&identity, server_id)
	steam_state.ticket_handle = steam.User_GetAuthSessionTicket(
		steam.User(),
		&steam_state.ticket[0],
		i32(len(steam_state.ticket)),
		&steam_state.ticket_len,
		identity,
	)
}

steam_cancel_ticket :: proc() {
	if !steam_state.initialized || steam_state.ticket_handle == steam.HAuthTicketInvalid do return
	steam.User_CancelAuthTicket(steam.User(), steam_state.ticket_handle)
	steam_state.ticket_handle = steam.HAuthTicketInvalid
	steam_state.ticket_len = 0
	steam_state.ticket_ready = false
}

// Empty when Steam is not up, which is also the caller's availability check.
steam_persona :: proc() -> string {
	return string(steam_state.persona[:steam_state.persona_len])
}

// The HUD font draws ASCII 32..95 only and hud_text walks bytes, so any other
// rune in a persona name would render as a hole. Unsupported runes become '_'.
@(private = "file")
sanitize_persona :: proc(raw: string) {
	n := 0
	for r in strings.trim_space(raw) {
		if n >= protocol.MAX_NAME do break
		c := u8('_')
		if r == ' ' || (r < 128 && hud_font_has_glyph(u8(r))) {
			c = u8(r)
		}
		steam_state.persona[n] = c
		n += 1
	}
	steam_state.persona_len = n
}

// Compiled in every build so the core:os import is never conditionally dead,
// which -vet-unused would reject; only STEAM_REQUIRED paths call it.
@(private = "file")
steam_exit :: proc(code: int) {
	os.exit(code)
}
