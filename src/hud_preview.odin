package main

import "core:log"
import "vendor:glfw"

// --hudpreview=<view>: the practice range with a competitive HUD state forced
// on top, so every comp element is screenshot-verifiable without a server.
// The range owns the world; this owns the match state the HUD reads. Applied
// every frame -- net_reset or the range cannot wash it away.

hud_preview_active :: proc() -> bool {
	return cli.hudpreview != "" && practice_active()
}

// Synthetic alive counts for the top bar; the range has no snapshots to walk.
HUD_PREVIEW_T_ALIVE :: 3
HUD_PREVIEW_CT_ALIVE :: 4

hud_preview_apply :: proc() {
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

	case:
		log.errorf("--hudpreview wants topbar, warmup, freeze, roundend or bomb, got {}", cli.hudpreview)
		cli.hudpreview = ""
		return
	}
	hud_preview.seeded = true
}

hud_preview: struct {
	seeded:          bool,
	bomb_planted_at: f64,
}
