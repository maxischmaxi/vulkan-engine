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

// A submitter now: everything lands in the banner bands, which own layout,
// priority and motion. The old y constants live in hud_banner.odin.
draw_round_hud :: proc(width, height: f32) {
	_ = width
	_ = height

	#partial switch net_client.phase {
	case .Warmup:
		seconds := max(int(math.ceil(net_client.time_left)), 0)
		banner_submit(
			.Headline,
			{
				head = "WARMUP",
				sub = fmt.tprintf("MATCH STARTS IN {}", seconds),
				note = "INFINITE MONEY - PRESS B TO BUY",
				color = HUD_WARN,
				priority = 60,
			},
		)

	case .Freeze:
		seconds := max(int(math.ceil(net_client.time_left)), 0)
		banner_submit(
			.Headline,
			{
				head = fmt.tprintf("ROUND {}", net_client.round),
				sub = fmt.tprintf("BUY TIME {}", seconds),
				note = "PRESS B TO BUY",
				color = HUD_WHITE,
				priority = 70,
			},
		)

	case .Halftime:
		banner_submit(.Headline, {head = "SWITCHING SIDES", color = HUD_WHITE, priority = 80})
	}

	// the transient round result outranks whatever phase text is up
	if glfw.GetTime() < hud_round.banner_until {
		banner_submit(
			.Headline,
			{
				head = hud_round.banner,
				sub = hud_round.banner_sub,
				note = hud_round.halftime_next ? "SWITCHING SIDES NEXT" : "",
				color = hud_round.banner_color,
				priority = 100,
			},
		)
	}

	// one quiet nudge once either side stands a round from winning
	if max(net_client.t_score, net_client.ct_score) == game.COMP_WIN_ROUNDS - 1 &&
	   (net_client.phase == .Freeze || net_client.phase == .Live) {
		banner_submit(.Top_Strip, {head = "MATCH POINT", color = HUD_WARN, priority = 50})
	}
}
