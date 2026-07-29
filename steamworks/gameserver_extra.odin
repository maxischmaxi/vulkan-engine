// Symbols the generated bindings are missing for running a dedicated game
// server: the gameserver interface accessor, its callback pipe, and the
// gameserver-side networking sockets accessor. All verified against the
// vendored .so with `nm -D redistributable_bin/linux64/libsteam_api.so`.
//
// steamworks.odin is a copy of jakubtomsu/odin-steamworks (commit 1c1f502,
// 2026-06-10, Steamworks SDK 1.60) with ONE deliberate patch: the
// CALLBACK_PACK_LARGE default follows Valve's per-OS packing (pack(4) on
// Linux/macOS, pack(8) on Windows) instead of upstream's always-large. Keep
// other local additions in this file; re-apply that patch on upstream updates.
package steamworks

when ODIN_OS == .Windows {
	foreign import gs_lib "redistributable_bin/win64/steam_api64.lib"
} else when ODIN_OS == .Linux {
	foreign import gs_lib "redistributable_bin/linux64/libsteam_api.so"
} else when ODIN_OS == .Darwin {
	foreign import gs_lib "redistributable_bin/osx/libsteam_api.dylib"
}

foreign gs_lib {
	SteamGameServer_RunCallbacks :: proc() ---
	SteamGameServer_GetHSteamPipe :: proc() -> HSteamPipe ---
	SteamGameServer_GetHSteamUser :: proc() -> HSteamUser ---
}

@(link_prefix = "SteamAPI_")
foreign gs_lib {
	SteamGameServer_v015 :: proc() -> ^IGameServer ---
	SteamGameServerNetworkingSockets_SteamAPI_v012 :: proc() -> ^INetworkingSockets ---
}

GameServer :: SteamGameServer_v015
GameServerNetworkingSockets_SteamAPI :: SteamGameServerNetworkingSockets_SteamAPI_v012
