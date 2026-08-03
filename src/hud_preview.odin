package main

import "core:log"
import "core:strings"
import "game"
import "vendor:glfw"

// --hudpreview=<view>: the practice range with a competitive HUD state forced
// on top, so every comp element is screenshot-verifiable without a server.
// The range owns the world; this owns the match state the HUD reads. Applied
// every frame -- net_reset or the range cannot wash it away.

hud_preview_active :: proc() -> bool {
	return cli.hudpreview != "" && practice_active()
}

// The previews that park on a menu screen rather than the range. They hold one
// screen still for the camera, so a stray click must not navigate away.
hud_preview_menu :: proc() -> bool {
	if cli.hudpreview == "" do return false
	return(
		cli.hudpreview == "menu" ||
		cli.hudpreview == "connecting" ||
		strings.has_prefix(cli.hudpreview, "modeselect") ||
		strings.has_prefix(cli.hudpreview, "teamselect") \
	)
}

// Synthetic alive counts for the top bar; the range has no snapshots to walk.
HUD_PREVIEW_T_ALIVE :: 3
HUD_PREVIEW_CT_ALIVE :: 4

hud_preview_apply :: proc() {
	// The menu previews never reach the range; they only pin the animation
	// clock so entrance staggers photograph mid-pose deterministically. The
	// select screens add a faked hover, because a mouse cannot be scripted.
	if cli.hudpreview == "menu" || cli.hudpreview == "connecting" {
		ui_anim_pin(0.5)
		return
	}
	if strings.has_prefix(cli.hudpreview, "modeselect") ||
	   strings.has_prefix(cli.hudpreview, "teamselect") {
		ui_anim_pin(0.5)
		switch {
		case strings.has_suffix(cli.hudpreview, "-hoverl"):
			hud_preview.hover = .Left
		case strings.has_suffix(cli.hudpreview, "-hoverr"):
			hud_preview.hover = .Right
		case:
			hud_preview.hover = .None
		}
		return
	}
	if !hud_preview_active() do return

	net_client.mode = .Comp
	net_client.team = .CT
	scene.chosen_team = .CT
	net_client.t_score = 7
	net_client.ct_score = 5
	net_client.round = 13
	net_client.money = 4750

	switch cli.hudpreview {
	case "topbar":
		net_client.phase = .Live
		net_client.time_left = 75

	case "warmup":
		net_client.phase = .Warmup
		net_client.time_left = 42

	case "freeze":
		net_client.phase = .Freeze
		net_client.time_left = 9

	case "roundend":
		net_client.phase = .Round_End
		net_client.time_left = 3
		// re-armed every frame so the banner never times out under the camera
		round_hud_show_result(.CT, .Bomb_Defused, false)

	case "bomb":
		// The fuse counts down for real so the blink accelerates on camera;
		// the local player poses as the defuser so the bar shows too.
		net_client.phase = .Bomb
		if !hud_preview.seeded {
			hud_preview.bomb_planted_at = glfw.GetTime()
			bomb_hud_note_state(.Planted)
		}
		elapsed := f32(glfw.GetTime() - hud_preview.bomb_planted_at)
		net_client.time_left = max(40 - elapsed, 0)
		net_client.bomb_state = .Planted
		net_client.bomb_defuser = net_client.pawn_id
		net_client.bomb_progress = clamp(elapsed / 10, 0, 1)

	case "killfeed":
		net_client.phase = .Live
		net_client.time_left = 75
		killfeed_preview_seed()

	case "scoreboard":
		net_client.phase = .Live
		net_client.time_left = 75
		scoreboard.forced = true

	case "buy":
		net_client.phase = .Freeze
		net_client.time_left = 9
		buy_menu.open = true

	case "nades", "nades-he", "nades-flash", "nades-smoke", "nades-molotov", "nades-c4":
		// A full belt plus the bomb, with one thing in the hands: the belt, the
		// stowed-weapon dimming and the held model all in one frame, without a
		// server and without a key press. The suffix picks what is held, which
		// is how each of the five poses gets photographed.
		net_client.phase = .Live
		net_client.time_left = 75
		player.grenades = {.He = 1, .Flash = 2, .Smoke = 1, .Molotov = 1}
		hud_preview.carry_bomb = true
		if !hud_preview.seeded {
			hand_pick(preview_hand(cli.hudpreview))
		}

	case "death":
		net_client.phase = .Live
		net_client.time_left = 75
		player.alive = false
		player.respawn_in = 2.4

	case "pause":
		net_client.phase = .Live
		net_client.time_left = 75
		scene.paused = true

	case "settings", "settings-audio", "settings-game", "settings-crosshair":
		settings_screen.open = true
		switch cli.hudpreview {
		case "settings":
			settings_screen.tab = .Video
		case "settings-audio":
			settings_screen.tab = .Audio
		case "settings-game":
			settings_screen.tab = .Game
		case "settings-crosshair":
			settings_screen.tab = .Crosshair
		}

	case:
		log.errorf(
			"--hudpreview wants topbar, warmup, freeze, roundend, bomb, nades[-KIND], killfeed, " +
			"scoreboard, buy, death, pause, settings*, outro, menu, connecting, " +
			"modeselect*, teamselect*, got {}",
			cli.hudpreview,
		)
		cli.hudpreview = ""
		return
	}
	hud_preview.seeded = true
}

// What --hudpreview=nades-<kind> puts in the hands; plain "nades" holds the
// smoke, which is the one whose silhouette shows the pose best.
@(private = "file")
preview_hand :: proc(view: string) -> game.Hand {
	switch view {
	case "nades-he":
		return {kind = .Grenade, index = i8(game.Grenade_Kind.He)}
	case "nades-flash":
		return {kind = .Grenade, index = i8(game.Grenade_Kind.Flash)}
	case "nades-molotov":
		return {kind = .Grenade, index = i8(game.Grenade_Kind.Molotov)}
	case "nades-c4":
		return {kind = .Bomb}
	}
	return {kind = .Grenade, index = i8(game.Grenade_Kind.Smoke)}
}

// Forces a settled hover on one half of a split select, so both states of the
// screen photograph without a scripted mouse.
Hud_Preview_Hover :: enum u8 {
	None,
	Left,
	Right,
}

// Authoritative while a menu preview runs: None means neither half is hovered,
// whatever the real cursor happens to sit on.
hud_preview_split_hover :: proc(left, right: ^bool) {
	if !hud_preview_menu() do return
	left^ = hud_preview.hover == .Left
	right^ = hud_preview.hover == .Right
}

hud_preview: struct {
	seeded:          bool,
	bomb_planted_at: f64,
	hover:           Hud_Preview_Hover,
	// The range has no bomb of its own; local_carries_bomb reads this so the
	// belt's C4 row and the bomb in the hands photograph.
	carry_bomb:      bool,
}
