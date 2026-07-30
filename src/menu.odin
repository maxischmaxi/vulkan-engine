package main

import "core:fmt"
import "game"
import "vendor:glfw"

// The menu screens, drawn with the HUD's own primitives. Immediate mode: a
// button draws itself and reports the click in one call, state lives nowhere.
// The font is uppercase-only and has no glyph for ? & ' -- labels avoid them.

MENU_DIM :: [4]f32{0.02, 0.02, 0.03, 0.60}
MENU_HOVER_BG :: [4]f32{0.16, 0.19, 0.23, 0.92}
MENU_T_COLOR :: [4]f32{0.85, 0.55, 0.20, 1} // attackers, warm
MENU_CT_COLOR :: [4]f32{0.30, 0.55, 0.90, 1} // defenders, cool

MENU_BUTTON_W :: f32(320)
MENU_BUTTON_H :: f32(64)

@(private = "file")
cursor_in :: proc(x, y, w, h: f32) -> bool {
	return(
		input.cursor_x >= x &&
		input.cursor_x < x + w &&
		input.cursor_y >= y &&
		input.cursor_y < y + h \
	)
}

// Draws the button and reports whether it was clicked this frame. The click
// latch is only consumed when the cursor is actually on the button, so one
// click can never press two things.
@(private = "file")
menu_button :: proc(x, y, w, h: f32, label: string, accent := HUD_WHITE) -> bool {
	scale := hud_scale()
	hovered := cursor_in(x, y, w, h)

	hud_rect(x, y, w, h, hovered ? MENU_HOVER_BG : HUD_PANEL, radius = 4 * scale)
	hud_frame(x, y, w, h, 2 * scale, hovered ? accent : HUD_FAINT)

	size := hud_font_size(HUD_TEXT_MEDIUM * scale)
	hud_text(x + w * 0.5, y + (h - size) * 0.5, label, size, hovered ? accent : HUD_DIM, .Center)

	return hovered && consume_click()
}

// One entry point for every non-Playing screen, called from build_hud.
draw_scene_screens :: proc(width, height: f32) {
	switch scene.current {
	case .Menu:
		draw_main_menu(width, height)
	case .Mode_Select:
		draw_mode_select(width, height)
	case .Team_Select:
		draw_team_select(width, height)
	case .Connecting:
		draw_connecting(width, height)
	case .Match_End:
		draw_match_end(width, height)
	case .Playing, .Practice:
	// unreachable: build_hud branches before calling this
	}

	// A click that hit no button dies here, so it cannot linger in the latch
	// and press whatever the cursor hovers next frame.
	_ = consume_click()
}

@(private = "file")
draw_main_menu :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)
	hud_text_shadow(cx, height * 0.24, "DUST2", hud_font_size(88 * scale), HUD_WHITE, .Center)

	if scene.error_text != "" {
		hud_text(cx, height * 0.38, scene.error_text, HUD_TEXT_SMALL * scale, HUD_BAD, .Center)
	}

	w := MENU_BUTTON_W * scale
	h := MENU_BUTTON_H * scale
	y := height * 0.46

	if menu_button(cx - w * 0.5, y, w, h, "PLAY") {
		enter_scene(.Mode_Select)
		return
	}
	if menu_button(cx - w * 0.5, y + h + 20 * scale, w, h, "PRACTICE") {
		start_practice()
		return
	}
	if menu_button(cx - w * 0.5, y + 2 * (h + 20 * scale), w, h, "QUIT") {
		glfw.SetWindowShouldClose(g.window, true)
		return
	}

	hud_text(
		cx,
		height - 40 * scale,
		"ESC RELEASES THE MOUSE IN GAME",
		HUD_TEXT_SMALL * 0.85 * scale,
		HUD_FAINT,
		.Center,
	)

	if steam_persona() != "" {
		hud_text_shadow(
			width - HUD_MARGIN * scale,
			height - 40 * scale,
			fmt.tprintf("STEAM: {}", steam_persona()),
			HUD_TEXT_SMALL * 0.85 * scale,
			HUD_FAINT,
			.Right,
		)
	}
}

// One of the two team cards: a coloured accent bar, the tag on top, the role
// underneath. Hand-rolled rather than menu_button because of the extra lines.
@(private = "file")
team_card :: proc(x, y, w, h: f32, tag, role: string, color: [4]f32) -> bool {
	scale := hud_scale()
	hovered := cursor_in(x, y, w, h)

	hud_rect(x, y, w, h, hovered ? MENU_HOVER_BG : HUD_PANEL, radius = 4 * scale)
	hud_frame(x, y, w, h, 2 * scale, hovered ? color : HUD_FAINT)
	hud_rect(x, y, 8 * scale, h, color, radius = 2 * scale)

	cx := x + w * 0.5
	hud_text_shadow(cx, y + h * 0.22, tag, hud_font_size(64 * scale), color, .Center)
	hud_text(
		cx,
		y + h * 0.64,
		role,
		HUD_TEXT_MEDIUM * scale,
		hovered ? HUD_WHITE : HUD_DIM,
		.Center,
	)

	return hovered && consume_click()
}

// TDM leads to the team pick; competitive queues right away, the server
// assigns the side. Until the matchmaking queue exists, both cards end at the
// same dev server -- the accept tells the client what that server runs.
@(private = "file")
draw_mode_select :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)
	hud_text_shadow(
		cx,
		height * 0.22,
		"CHOOSE MODE",
		hud_font_size(48 * scale),
		HUD_WHITE,
		.Center,
	)

	card_w := 380 * scale
	card_h := 240 * scale
	gap := 40 * scale
	y := height * 0.36

	if team_card(cx - card_w - gap * 0.5, y, card_w, card_h, "TDM", "TEAM DEATHMATCH", HUD_DIM) {
		scene.chosen_mode = .TDM
		enter_scene(.Team_Select)
		return
	}
	if team_card(cx + gap * 0.5, y, card_w, card_h, "COMP", "5V5 - FIRST TO 13", HUD_WARN) {
		scene.chosen_mode = .Comp
		scene.chosen_team = .T // a wish; the server balances
		scene.queue_pending = true
		enter_scene(.Connecting)
		return
	}

	w := MENU_BUTTON_W * scale
	if menu_button(cx - w * 0.5, height * 0.74, w, 56 * scale, "BACK") {
		enter_scene(.Menu)
	}
}

@(private = "file")
draw_team_select :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)
	hud_text_shadow(
		cx,
		height * 0.22,
		"CHOOSE TEAM",
		hud_font_size(48 * scale),
		HUD_WHITE,
		.Center,
	)

	card_w := 380 * scale
	card_h := 240 * scale
	gap := 40 * scale
	y := height * 0.36

	if team_card(cx - card_w - gap * 0.5, y, card_w, card_h, "T", "ATTACKERS", MENU_T_COLOR) {
		scene.chosen_team = .T
		start_game()
		return
	}
	if team_card(cx + gap * 0.5, y, card_w, card_h, "CT", "DEFENDERS", MENU_CT_COLOR) {
		scene.chosen_team = .CT
		start_game()
		return
	}

	w := MENU_BUTTON_W * scale
	if menu_button(cx - w * 0.5, height * 0.74, w, 56 * scale, "BACK") {
		enter_scene(.Menu)
	}
}

@(private = "file")
start_game :: proc() {
	// Menu play goes through the queue whenever a master is configured; the
	// legacy quickplay query stays for --join and master-less dev loops.
	scene.queue_pending = true
	enter_scene(.Connecting)
}

// Doubles as the queue screen: the elapsed clock spans queue, server spawn
// and handshake, so a player always sees how long they have been waiting.
@(private = "file")
draw_connecting :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)

	elapsed := max(int(glfw.GetTime() - scene.queue_started), 0)
	hud_text_shadow(
		cx,
		height * 0.34,
		fmt.tprintf("{}:{:02d}", elapsed / 60, elapsed % 60),
		hud_font_size(HUD_TEXT_BIG * scale),
		HUD_WHITE,
		.Center,
	)

	// The dots animate after the fixed label so the label itself never shifts.
	label := connecting_label()
	size := hud_font_size(HUD_TEXT_MEDIUM * scale)
	pen := hud_text_shadow(cx, height * 0.42, label, size, HUD_WHITE, .Center)
	dots := int(glfw.GetTime() * 2) % 3 + 1
	hud_text(pen, height * 0.42, fmt.tprintf("%.*s", dots, "..."), size, HUD_WHITE)

	w := MENU_BUTTON_W * scale
	if menu_button(cx - w * 0.5, height * 0.58, w, 56 * scale, "CANCEL") {
		enter_scene(.Menu)
	}
}

@(private = "file")
draw_match_end :: proc(width, height: f32) {
	if scene.final_mode == .Comp {
		draw_match_outro(width, height)
		return
	}

	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)

	// The result from the player's own side of the scoreboard.
	own := scene.chosen_team == .T ? scene.final_t : scene.final_ct
	other := scene.chosen_team == .T ? scene.final_ct : scene.final_t
	headline := "DRAW"
	color := HUD_DIM
	if own > other {
		headline = "VICTORY"
		color = HUD_GOOD
	} else if own < other {
		headline = "DEFEAT"
		color = HUD_BAD
	}
	hud_text_shadow(cx, height * 0.28, headline, hud_font_size(88 * scale), color, .Center)

	// T left, CT right, each in its colour, the score white between them.
	score := fmt.tprintf("{} : {}", scene.final_t, scene.final_ct)
	size := hud_font_size(40 * scale)
	score_w := hud_text_width(score, size)
	hud_text_shadow(cx, height * 0.28 + 110 * scale, score, size, HUD_WHITE, .Center)
	hud_text(
		cx - score_w * 0.5 - 24 * scale,
		height * 0.28 + 110 * scale,
		"T",
		size,
		MENU_T_COLOR,
		.Right,
	)
	hud_text(
		cx + score_w * 0.5 + 24 * scale,
		height * 0.28 + 110 * scale,
		"CT",
		size,
		MENU_CT_COLOR,
	)

	remaining := max(0, int(scene.end_at - glfw.GetTime()) + 1)
	hud_text(
		cx,
		height * 0.28 + 165 * scale,
		fmt.tprintf("MENU IN {}", remaining),
		HUD_TEXT_SMALL * scale,
		HUD_FAINT,
		.Center,
	)

	w := MENU_BUTTON_W * scale
	if menu_button(cx - w * 0.5, height * 0.62, w, 56 * scale, "CONTINUE") {
		enter_scene(.Menu)
	}
}

// The competitive outro: the winning team on a podium of plain rectangles --
// five bodies with heads, the middle one tallest -- under the final score.
// Real models replace the rectangles one day; the composition stays. Reads
// only scene fields: the connection is long gone by now.
@(private = "file")
draw_match_outro :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)

	draw := scene.final_winner == game.NO_WINNER
	win_color := HUD_DIM
	headline := "MATCH DRAW"
	if !draw {
		winner := game.Team(scene.final_winner)
		win_color = winner == .T ? MENU_T_COLOR : MENU_CT_COLOR
		headline = winner == .T ? "TERRORISTS WIN THE MATCH" : "COUNTER-TERRORISTS WIN THE MATCH"
	}
	hud_text_shadow(cx, height * 0.14, headline, hud_font_size(48 * scale), win_color, .Center)

	// the final score, T and CT tagged in their colours
	score := fmt.tprintf("{} : {}", scene.final_t, scene.final_ct)
	size := hud_font_size(56 * scale)
	score_w := hud_text_width(score, size)
	score_y := height * 0.14 + 70 * scale
	hud_text_shadow(cx, score_y, score, size, HUD_WHITE, .Center)
	hud_text(cx - score_w * 0.5 - 24 * scale, score_y, "T", size, MENU_T_COLOR, .Right)
	hud_text(cx + score_w * 0.5 + 24 * scale, score_y, "CT", size, MENU_CT_COLOR)

	// the podium: five winner-coloured figures, skipped on a draw
	if !draw {
		body_w := 56 * scale
		gap := 20 * scale
		heights := [5]f32{120, 145, 170, 145, 120}
		base_y := height * 0.72
		total := 5 * body_w + 4 * gap

		hud_rect(
			cx - total * 0.5 - 30 * scale,
			base_y,
			total + 60 * scale,
			14 * scale,
			{0.10, 0.11, 0.13, 0.95},
			radius = 4 * scale,
		)
		x := cx - total * 0.5
		for i in 0 ..< 5 {
			h := heights[i] * scale
			head := 26 * scale
			hud_rect(x, base_y - h, body_w, h, win_color, radius = 6 * scale)
			hud_rect(
				x + (body_w - head) * 0.5,
				base_y - h - head - 6 * scale,
				head,
				head,
				win_color,
				radius = head * 0.5,
			)
			x += body_w + gap
		}
	}

	remaining := max(0, int(scene.end_at - glfw.GetTime()) + 1)
	hud_text(
		cx,
		height * 0.80,
		fmt.tprintf("MENU IN {}", remaining),
		HUD_TEXT_SMALL * scale,
		HUD_FAINT,
		.Center,
	)

	w := MENU_BUTTON_W * scale
	if menu_button(cx - w * 0.5, height * 0.86, w, 56 * scale, "CONTINUE") {
		enter_scene(.Menu)
		return
	}
	// a click anywhere else skips the outro too
	if consume_click() {
		enter_scene(.Menu)
	}
}

// The ESC overlay during play. The world keeps simulating behind it.
draw_pause_overlay :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, {0.02, 0.02, 0.03, 0.45})
	hud_text_shadow(cx, height * 0.32, "PAUSED", hud_font_size(48 * scale), HUD_WHITE, .Center)

	w := MENU_BUTTON_W * scale
	h := 56 * scale
	y := height * 0.46

	leave := practice_active() ? "LEAVE PRACTICE" : "LEAVE MATCH"
	if menu_button(cx - w * 0.5, y, w, h, "RESUME") {
		scene.paused = false
		grab_cursor(true)
	} else if menu_button(cx - w * 0.5, y + h + 20 * scale, w, h, leave) {
		enter_scene(.Menu)
	} else if !practice_active() {
		hud_text(
			cx,
			y + 2 * (h + 20 * scale),
			"THE MATCH KEEPS RUNNING",
			HUD_TEXT_SMALL * 0.85 * scale,
			HUD_FAINT,
			.Center,
		)
	}

	_ = consume_click()
}
