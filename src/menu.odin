package main

import "core:fmt"
import "core:math"
import "game"
import "vendor:glfw"

// The menu screens, drawn with the HUD's own primitives. Immediate mode: a
// button draws itself and reports the click in one call, state lives nowhere.
// The font is uppercase-only and has no glyph for ? & ' -- labels avoid them.

MENU_BUTTON_W :: f32(320)
MENU_BUTTON_H :: f32(64)

// Buttons and hover state live in ui.odin now; this file only lays screens out.

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

// Valorant's own pattern: a left nav rail over a gradient scrim, the live map
// as the backdrop. The centre of the screen stays open on purpose.
@(private = "file")
draw_main_menu :: proc(width, height: f32) {
	scale := hud_scale()
	rail_x := width * 0.08

	// darkest at the left, gone by mid-screen
	hud_rect_gradient(0, 0, width * 0.62, height, ui_fade(UI_BG, 0.97))

	title_dy, title_a := ui_entrance(0)
	title_size := hud_font_size(UI_DISPLAY * scale)
	title_y := height * 0.14 + title_dy
	hud_text(rail_x, title_y, "DUST2", title_size, ui_fade(UI_TEXT, title_a))
	sub_size := hud_font_size(UI_LABEL * scale)
	hud_text(
		rail_x + 3 * scale,
		title_y + title_size + 10 * scale,
		"TACTICAL SHOOTER PROTOTYPE",
		sub_size,
		ui_fade(UI_TEXT_FAINT, title_a),
		tracking = sub_size * 0.24,
	)

	if scene.error_text != "" {
		hud_text(rail_x, height * 0.34, scene.error_text, UI_LABEL * scale, UI_ACCENT)
	}

	w := 300 * scale
	h := 52 * scale
	y := height * 0.42
	gap := 10 * scale

	dy1, a1 := ui_entrance(1)
	dy2, a2 := ui_entrance(2)
	dy3, a3 := ui_entrance(3)
	dy4, a4 := ui_entrance(4)
	if ui_button(rail_x - 14 * scale, y + dy1, w, h, "PLAY", variant = .Ghost, fade = a1) {
		scene_transition_to(.Mode_Select)
		return
	}
	if ui_button(rail_x - 14 * scale, y + h + gap + dy2, w, h, "PRACTICE", variant = .Ghost, fade = a2) {
		start_practice()
		return
	}
	if ui_button(rail_x - 14 * scale, y + 2 * (h + gap) + dy3, w, h, "SETTINGS", variant = .Ghost, fade = a3) {
		open_settings_screen()
		return
	}
	if ui_button(rail_x - 14 * scale, y + 3 * (h + gap) + dy4, w, h, "QUIT", variant = .Ghost_Danger, fade = a4) {
		glfw.SetWindowShouldClose(g.window, true)
		return
	}

	hud_text(
		rail_x,
		height - 40 * scale,
		"ESC RELEASES THE MOUSE IN GAME",
		hud_font_size(UI_MICRO * scale),
		HUD_FAINT,
	)

	if steam_persona() != "" {
		hud_text_shadow(
			width - HUD_MARGIN * scale,
			height - 40 * scale,
			fmt.tprintf("STEAM: {}", steam_persona()),
			hud_font_size(UI_LABEL * scale),
			HUD_FAINT,
			.Right,
		)
	}
}

// One of the two team cards: a coloured top rule, the tag on top, the role
// underneath. Hand-rolled rather than ui_button because of the extra lines,
// but the hover state comes from the shared ui_hot.
@(private = "file")
team_card :: proc(x, y, w, h: f32, tag, role: string, color: [4]f32) -> bool {
	scale := hud_scale()
	hovered, t := ui_hot(ui_id(tag), x, y, w, h)
	e := ease_out_cubic(t)

	// the card grows 2% around its centre on hover and floods with a whisper
	// of its team colour
	grow := 1 + 0.02 * e
	gx := x - (grow - 1) * w * 0.5
	gy := y - (grow - 1) * h * 0.5
	gw := w * grow
	gh := h * grow

	bg := ui_mix(ui_mix(UI_PANEL, UI_PANEL_RAISED, t), color, 0.08 * t)
	bg.a = UI_PANEL.a
	hud_rect(gx, gy, gw, gh, bg, radius = UI_RADIUS * scale)
	hud_frame(gx, gy, gw, gh, UI_STROKE_W * scale, ui_mix(UI_STROKE, color, t))
	hud_rect(gx, gy, gw, 3 * scale, color)

	cx := gx + gw * 0.5
	hud_text_shadow(cx, gy + gh * 0.20, tag, hud_font_size(64 * scale), color, .Center)
	size := hud_font_size(UI_BODY * scale)
	hud_text(
		cx,
		gy + gh * 0.64,
		role,
		size,
		ui_mix(UI_TEXT_DIM, UI_TEXT, t),
		.Center,
		tracking = size * 0.14,
	)

	return ui_clicked(hovered)
}

// TDM leads to the team pick; competitive queues right away, the server
// assigns the side. Until the matchmaking queue exists, both cards end at the
// same dev server -- the accept tells the client what that server runs.
@(private = "file")
draw_mode_select :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)
	head_size := hud_font_size(UI_H1 * scale)
	hud_text(
		width * 0.08,
		height * 0.14,
		"CHOOSE MODE",
		head_size,
		HUD_WHITE,
		tracking = head_size * 0.10,
	)

	card_w := 380 * scale
	card_h := 240 * scale
	gap := 40 * scale
	y := height * 0.36

	if team_card(cx - card_w - gap * 0.5, y, card_w, card_h, "TDM", "TEAM DEATHMATCH", HUD_DIM) {
		scene.chosen_mode = .TDM
		scene_transition_to(.Team_Select)
		return
	}
	if team_card(cx + gap * 0.5, y, card_w, card_h, "COMP", "5V5 - FIRST TO 13", HUD_WARN) {
		scene.chosen_mode = .Comp
		scene.chosen_team = .T // a wish; the server balances
		scene.queue_pending = true
		scene_transition_to(.Connecting)
		return
	}

	if ui_button(width * 0.08 - 14 * scale, height * 0.86, 200 * scale, 52 * scale, "BACK", variant = .Ghost) {
		scene_transition_to(.Menu)
	}
}

@(private = "file")
draw_team_select :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	hud_rect(0, 0, width, height, MENU_DIM)
	head_size := hud_font_size(UI_H1 * scale)
	hud_text(
		width * 0.08,
		height * 0.14,
		"CHOOSE TEAM",
		head_size,
		HUD_WHITE,
		tracking = head_size * 0.10,
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

	if ui_button(width * 0.08 - 14 * scale, height * 0.86, 200 * scale, 52 * scale, "BACK", variant = .Ghost) {
		scene_transition_to(.Menu)
	}
}

@(private = "file")
start_game :: proc() {
	// Menu play goes through the queue whenever a master is configured; the
	// legacy quickplay query stays for --join and master-less dev loops.
	scene.queue_pending = true
	scene_transition_to(.Connecting)
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

	// A letter-spaced status line over an indeterminate accent sweep: the one
	// screen where restraint reads as polish.
	size := hud_font_size(UI_LABEL * scale)
	hud_text_shadow(
		cx,
		height * 0.42,
		connecting_label(),
		size,
		HUD_WHITE,
		.Center,
		tracking = size * 0.18,
	)

	bar_w := 260 * scale
	seg := 70 * scale
	bar_y := height * 0.42 + size + 16 * scale
	phase := f32(math.mod(glfw.GetTime(), 2.4)) / 2.4
	tri := 1 - abs(2 * phase - 1)
	sweep := ease_in_out_cubic(f32(tri))
	hud_rect(cx - bar_w * 0.5, bar_y, bar_w, 2 * scale, ui_fade(UI_STROKE, 0.8))
	hud_rect(cx - bar_w * 0.5 + (bar_w - seg) * sweep, bar_y, seg, 2 * scale, UI_ACCENT)

	w := MENU_BUTTON_W * scale
	if ui_button(cx - w * 0.5, height * 0.58, w, 56 * scale, "CANCEL") {
		scene_transition_to(.Menu)
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
	if ui_button(cx - w * 0.5, height * 0.62, w, 56 * scale, "CONTINUE", variant = .Primary) {
		scene_transition_to(.Menu)
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

	// the podium: five winner-coloured figures rising from the base, staggered
	// -- the one place a longer animation is earned. Skipped on a draw.
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
			UI_PANEL_RAISED,
			radius = 4 * scale,
		)
		x := cx - total * 0.5
		for i in 0 ..< 5 {
			rise := ease_out_cubic(clamp((ui_screen_age() - 0.3 - f32(i) * 0.08) / 0.3, 0, 1))
			h := heights[i] * scale * rise
			head := 26 * scale
			if h > 1 {
				hud_rect(x, base_y - h, body_w, h, ui_fade(win_color, 0.9), radius = 6 * scale)
				hud_rect(
					x + (body_w - head) * 0.5,
					base_y - h - head - 6 * scale,
					head,
					head,
					ui_fade(win_color, 0.9 * rise),
					radius = head * 0.5,
				)
			}
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
	if ui_button(cx - w * 0.5, height * 0.86, w, 56 * scale, "CONTINUE", variant = .Primary) {
		scene_transition_to(.Menu)
		return
	}
	// a click anywhere else skips the outro too
	if consume_click() {
		scene_transition_to(.Menu)
	}
}

// The ESC overlay during play: the main menu's rail in miniature, over a
// light scrim. The world keeps simulating behind it.
draw_pause_overlay :: proc(width, height: f32) {
	scale := hud_scale()
	rail_x := width * 0.08

	hud_rect_gradient(0, 0, width * 0.58, height, ui_fade(UI_BG, 0.80))

	title_size := hud_font_size(UI_H1 * scale)
	hud_text(rail_x, height * 0.30, "PAUSED", title_size, UI_TEXT, tracking = title_size * 0.10)

	w := 300 * scale
	h := 52 * scale
	y := height * 0.42
	gap := 10 * scale

	leave := practice_active() ? "LEAVE PRACTICE" : "LEAVE MATCH"
	if ui_button(rail_x - 14 * scale, y, w, h, "RESUME", variant = .Ghost) {
		scene.paused = false
		grab_cursor(true)
	} else if ui_button(rail_x - 14 * scale, y + h + gap, w, h, "SETTINGS", variant = .Ghost) {
		open_settings_screen()
	} else if ui_button(rail_x - 14 * scale, y + 2 * (h + gap), w, h, leave, variant = .Ghost_Danger) {
		scene_transition_to(.Menu)
	} else if !practice_active() {
		hud_text(
			rail_x,
			y + 3 * (h + gap) + 8 * scale,
			"THE MATCH KEEPS RUNNING",
			hud_font_size(UI_MICRO * scale),
			HUD_FAINT,
		)
	}

	_ = consume_click()
}
