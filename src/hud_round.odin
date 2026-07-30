package main

import "core:fmt"
import "core:math"
import "game"
import "protocol"
import "vendor:glfw"

// Competitive round messaging: the warmup banner, the freeze-time round
// header, and the transient round-result banner with its reason line. Phase
// texts draw off net_client state directly; the result banner is the one
// piece of retained state, seeded by the Match_Phase message and gone four
// seconds later.

ROUND_BANNER_SECONDS :: 4.0

hud_round: struct {
	banner:       string,
	banner_sub:   string,
	banner_color: [4]f32,
	banner_until: f64,
	// A halftime follows this round end: announce it under the result.
	halftime_next: bool,
}

// Called from handle_match_phase for every comp phase message.
round_hud_note_phase :: proc(m: protocol.Match_Phase_Msg) {
	#partial switch m.phase {
	case .Round_End:
		if m.reason == .Match_Over do return // the outro owns the ending
		if m.winner == game.NO_WINNER do return
		halftime_next := int(m.round) == game.COMP_HALF_ROUNDS
		round_hud_show_result(game.Team(m.winner), m.reason, halftime_next)

	case .Freeze, .Warmup:
		// A new round washes the old banner away early.
		hud_round.banner_until = 0
	}
}

round_hud_show_result :: proc(winner: game.Team, reason: game.Round_End_Reason, halftime_next: bool) {
	if winner == .T {
		hud_round.banner = "TERRORISTS WIN"
		hud_round.banner_color = MENU_T_COLOR
	} else {
		hud_round.banner = "COUNTER-TERRORISTS WIN"
		hud_round.banner_color = MENU_CT_COLOR
	}
	hud_round.banner_sub = round_reason_text(reason)
	hud_round.banner_until = glfw.GetTime() + ROUND_BANNER_SECONDS
	hud_round.halftime_next = halftime_next
}

@(private = "file")
round_reason_text :: proc(reason: game.Round_End_Reason) -> string {
	// Mind the font: no ? & ' anywhere in these.
	#partial switch reason {
	case .Elimination:
		return "ENEMY TEAM ELIMINATED"
	case .Bomb_Exploded:
		return "TARGET DESTROYED"
	case .Bomb_Defused:
		return "BOMB DEFUSED"
	case .Time_Out:
		return "TIME EXPIRED"
	}
	return ""
}

draw_round_hud :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	#partial switch net_client.phase {
	case .Warmup:
		seconds := max(int(math.ceil(net_client.time_left)), 0)
		hud_text_shadow(cx, height * 0.28, "WARMUP", hud_font_size(HUD_TEXT_BIG * scale), HUD_WARN, .Center)
		hud_text_shadow(
			cx,
			height * 0.28 + 52 * scale,
			fmt.tprintf("MATCH STARTS IN {}", seconds),
			HUD_TEXT_MEDIUM * scale,
			HUD_WHITE,
			.Center,
		)
		hud_text(
			cx,
			height * 0.28 + 84 * scale,
			"INFINITE MONEY - PRESS B TO BUY",
			HUD_TEXT_SMALL * scale,
			HUD_DIM,
			.Center,
		)

	case .Freeze:
		seconds := max(int(math.ceil(net_client.time_left)), 0)
		hud_text_shadow(
			cx,
			height * 0.28,
			fmt.tprintf("ROUND {}", net_client.round),
			hud_font_size(HUD_TEXT_BIG * scale),
			HUD_WHITE,
			.Center,
		)
		hud_text_shadow(
			cx,
			height * 0.28 + 52 * scale,
			fmt.tprintf("BUY TIME {}", seconds),
			HUD_TEXT_MEDIUM * scale,
			HUD_WARN,
			.Center,
		)
		hud_text(
			cx,
			height * 0.28 + 84 * scale,
			"PRESS B TO BUY",
			HUD_TEXT_SMALL * scale,
			HUD_DIM,
			.Center,
		)

	case .Halftime:
		hud_text_shadow(
			cx,
			height * 0.28,
			"SWITCHING SIDES",
			hud_font_size(HUD_TEXT_BIG * scale),
			HUD_WHITE,
			.Center,
		)
	}

	// the transient round result, over whatever phase text is up
	if glfw.GetTime() < hud_round.banner_until {
		hud_text_shadow(
			cx,
			height * 0.36,
			hud_round.banner,
			hud_font_size(HUD_TEXT_BIG * scale),
			hud_round.banner_color,
			.Center,
		)
		if hud_round.banner_sub != "" {
			hud_text_shadow(
				cx,
				height * 0.36 + 52 * scale,
				hud_round.banner_sub,
				HUD_TEXT_MEDIUM * scale,
				HUD_WHITE,
				.Center,
			)
		}
		if hud_round.halftime_next {
			hud_text(
				cx,
				height * 0.36 + 84 * scale,
				"SWITCHING SIDES NEXT",
				HUD_TEXT_SMALL * scale,
				HUD_DIM,
				.Center,
			)
		}
	}

	// one quiet nudge once either side stands a round from winning
	if max(net_client.t_score, net_client.ct_score) == game.COMP_WIN_ROUNDS - 1 &&
	   (net_client.phase == .Freeze || net_client.phase == .Live) {
		hud_text_shadow(cx, height * 0.20, "MATCH POINT", HUD_TEXT_SMALL * scale, HUD_WARN, .Center)
	}
}
