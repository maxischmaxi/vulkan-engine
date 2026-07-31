package main

import "game"
import "vendor:glfw"

// The bomb's HUD: the carrier tag, the planted banner, the plant/defuse
// progress bar. State arrives as the snapshot's bomb block mirrored into
// net_client; the one retained piece here is the planted banner's clock,
// armed by the state edge in handle_snapshot.

BOMB_BANNER_SECONDS :: 3.0

hud_bomb: struct {
	planted_banner_until: f64,
}

// The state edge, from handle_snapshot. Only the plant needs a banner --
// defused and exploded rounds get theirs from the round result.
bomb_hud_note_state :: proc(state: game.Bomb_State) {
	if state == .Planted {
		hud_bomb.planted_banner_until = glfw.GetTime() + BOMB_BANNER_SECONDS
		audio_emit({kind = .Bomb_Planted, local = true})
	}
}

draw_bomb_hud :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	// the carrier tag, above the weapon slots
	if net_client.bomb_state == .Carried && net_client.bomb_carrier == net_client.pawn_id {
		tag_y := height - HUD_MARGIN * scale - HUD_SLOT_HEIGHT * scale - 46 * scale
		s := 14 * scale
		hud_rect(cx - 34 * scale, tag_y + 1 * scale, s, s, MENU_T_COLOR, radius = 3 * scale)
		hud_text_shadow(cx - 34 * scale + s + 8 * scale, tag_y, "BOMB", HUD_TEXT_SMALL * scale, HUD_WHITE)
	}

	if glfw.GetTime() < hud_bomb.planted_banner_until {
		hud_text_shadow(
			cx,
			height * 0.32,
			"THE BOMB HAS BEEN PLANTED",
			HUD_TEXT_MEDIUM * scale,
			HUD_BAD,
			.Center,
		)
	}

	// the progress bar, reload-bar style under the crosshair
	label := ""
	if net_client.bomb_state == .Carried &&
	   net_client.bomb_carrier == net_client.pawn_id &&
	   net_client.bomb_progress > 0 {
		label = "PLANTING"
	}
	if net_client.bomb_state == .Planted && net_client.bomb_defuser == net_client.pawn_id {
		label = "DEFUSING"
	}
	if label == "" do return

	color := label == "PLANTING" ? HUD_WARN : HUD_GOOD
	bar_w := 120 * scale
	bar_h := 6 * scale
	bar_y := height * 0.5 + 46 * scale
	hud_text_shadow(cx, bar_y - HUD_TEXT_SMALL * scale - 6 * scale, label, HUD_TEXT_SMALL * scale, color, .Center)
	hud_rect(cx - bar_w * 0.5, bar_y, bar_w, bar_h, HUD_PANEL, radius = 2 * scale)
	hud_rect(cx - bar_w * 0.5, bar_y, bar_w * clamp(net_client.bomb_progress, 0, 1), bar_h, color, radius = 2 * scale)
}
