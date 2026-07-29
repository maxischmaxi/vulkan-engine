package main

import "core:fmt"
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
	hud_text(
		cx,
		height * 0.24 + 96 * scale,
		"TEAM DEATHMATCH",
		HUD_TEXT_SMALL * scale,
		HUD_DIM,
		.Center,
	)

	if scene.error_text != "" {
		hud_text(cx, height * 0.38, scene.error_text, HUD_TEXT_SMALL * scale, HUD_BAD, .Center)
	}

	w := MENU_BUTTON_W * scale
	h := MENU_BUTTON_H * scale
	y := height * 0.46

	if menu_button(cx - w * 0.5, y, w, h, "PLAY") {
		enter_scene(.Team_Select)
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
	enter_scene(.Connecting)
}

@(private = "file")
draw_connecting :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)

	// The dots animate after the fixed label so the label itself never shifts.
	label := "CONNECTING TO SERVER"
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
