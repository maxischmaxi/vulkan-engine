package main

import "core:fmt"
import "core:math"
import "core:strings"
import "game"
import "vendor:glfw"

// The two selection screens, both drawn as one full-screen choice: a skewed
// divider, one option per half, the hovered side flooding with its colour while
// the other falls back. Clicking anywhere in a half picks it -- the whole screen
// is the button, which is what makes the pick feel like a commitment.

// Divider skew in reference pixels: the top edge sits this far right of centre,
// the bottom edge this far left.
SPLIT_SKEW :: f32(48)
// How far the divider yields toward the un-hovered side.
SPLIT_SHIFT :: f32(40)
// Roster rows a half shows before collapsing the rest into "+N MORE".
SELECT_ROSTER_ROWS :: game.TEAM_SIZE

Select_Slot :: struct {
	name:  string,
	bot:   bool,
	local: bool,
}

Split_Half :: struct {
	tag:           string, // doubles as the hover id
	subtitle:      string,
	lines:         [2]string, // micro detail lines; empty ones are skipped
	color:         [4]f32,
	disabled:      bool,
	disabled_note: string, // replaces the hover hint while disabled
	hint:          string,
	slots:         []Select_Slot, // nil draws no roster table
	slot_cap:      int, // rows including the open ones
}

// Which half a click landed in.
Split_Pick :: enum {
	None,
	Left,
	Right,
}

// ---------------------------------------------------------------- the screens

// TDM leads to the team pick; competitive queues right away, the server
// assigns the side.
draw_mode_select :: proc(width, height: f32) {
	// Cool against warm. The signature red is deliberately absent: flooding
	// half the screen with it reads as damage, not as a game mode.
	left := Split_Half {
		tag      = "TDM",
		subtitle = "TEAM DEATHMATCH",
		lines    = {"INSTANT RESPAWN", "PICK YOUR SIDE"},
		color    = UI_CT_COLOR,
		hint     = "CLICK TO SELECT",
	}
	right := Split_Half {
		tag      = "COMP",
		subtitle = "COMPETITIVE",
		lines    = {"5V5 - FIRST TO 13", "SERVER ASSIGNS SIDES"},
		color    = UI_WARN,
		hint     = "CLICK TO SELECT",
	}

	pick, back := draw_split_select(width, height, "CHOOSE MODE", left, right)
	switch pick {
	case .Left:
		scene.chosen_mode = .TDM
		scene_transition_to(.Team_Select)
		return
	case .Right:
		scene.chosen_mode = .Comp
		scene.chosen_team = .T // a wish; the server balances
		scene.queue_pending = true
		scene_transition_to(.Connecting)
		return
	case .None:
	}
	if back do scene_transition_to(.Menu)
}

// The lineup is live: the client is connected and watching snapshots while it
// decides, so both sides show who is already in the match.
draw_team_select :: proc(width, height: f32) {
	roster := gather_select_roster()

	left := split_team_half("T", "ATTACKERS", UI_T_COLOR, &roster, .T)
	right := split_team_half("CT", "DEFENDERS", UI_CT_COLOR, &roster, .CT)

	pick, back := draw_split_select(
		width,
		height,
		"CHOOSE TEAM",
		left,
		right,
		connecting = roster.connecting,
	)
	switch pick {
	case .Left:
		team_select_pick(.T)
		return
	case .Right:
		team_select_pick(.CT)
		return
	case .None:
	}
	if back do scene_transition_to(.Mode_Select)
}

@(private = "file")
split_team_half :: proc(
	tag, subtitle: string,
	color: [4]f32,
	roster: ^Select_Roster,
	team: game.Team,
) -> Split_Half {
	humans := roster.humans[team]
	return Split_Half {
		tag = tag,
		subtitle = subtitle,
		lines = {fmt.tprintf("{} OF {} PLAYERS", humans, game.TEAM_SIZE), ""},
		color = color,
		disabled = humans >= game.TEAM_SIZE,
		disabled_note = "TEAM FULL",
		hint = "CLICK TO JOIN",
		slots = roster.slots[team][:roster.filled[team]],
		slot_cap = game.TEAM_SIZE,
	}
}

// ------------------------------------------------------------- the split view

draw_split_select :: proc(
	width, height: f32,
	title: string,
	left, right: Split_Half,
	connecting := false,
) -> (
	pick: Split_Pick,
	back: bool,
) {
	scale := hud_scale()
	age := ui_screen_age()

	skew := SPLIT_SKEW * scale
	rot := math.atan(2 * skew / height)

	// The hit test runs against the resting line, never the animated one: a
	// divider that moves under the cursor would flip the hover back and forth.
	div_rest :: proc(width, height, skew, y: f32) -> f32 {
		return width * 0.5 + skew * (1 - 2 * y / height)
	}

	// BACK sits on the divider, so its rect is the one place neither half
	// lights up.
	back_w := 160 * scale
	back_h := 44 * scale
	back_x := width * 0.5 - back_w * 0.5
	back_y := height * 0.905
	back_hover, back_t := ui_hot(ui_id("BACK"), back_x, back_y, back_w, back_h)

	inside := cursor_in(0, 0, width, height) && !back_hover
	on_left := input.cursor_x < div_rest(width, height, skew, input.cursor_y)
	hov_l := inside && !left.disabled && on_left
	hov_r := inside && !right.disabled && !on_left
	hud_preview_split_hover(&hov_l, &hov_r)

	t_l := ui_hot_manual(ui_id(left.tag), hov_l)
	t_r := ui_hot_manual(ui_id(right.tag), hov_r)
	e_l := ease_out_cubic(t_l)
	e_r := ease_out_cubic(t_r)

	// entrance: the halves slide in from their outer edges, the divider grows
	// out of the centre, everything settles well before the pinned 0.5 s
	en_l := ease_out_cubic(clamp((age - 0.04) / 0.35, 0, 1))
	en_r := ease_out_cubic(clamp((age - 0.10) / 0.35, 0, 1))
	div_enter := ease_out_cubic(clamp((age - 0.12) / 0.30, 0, 1))
	dx_l := -(1 - en_l) * 48 * scale
	dx_r := (1 - en_r) * 48 * scale

	mid := width * 0.5 + SPLIT_SHIFT * scale * (e_l - e_r)
	cy := height * 0.5

	// 1 -- the scrim over the live map. Heavier than the panel screens use:
	// the map is the whole backdrop here, and it has to sink far enough for
	// the team colours to read as the brightest thing on screen.
	hud_rect(0, 0, width, height, UI_SCRIM_HEAVY)

	// 2, 3 -- each half floods with its own colour, dimmed by the other's hover
	flood_w := width * 0.75
	flood_h := height * 1.5
	half_cx := flood_w * 0.5 * math.cos(rot)
	half_cy := flood_w * 0.5 * math.sin(rot)
	hud_rect_rotated(
		mid - half_cx,
		cy - half_cy,
		flood_w,
		flood_h,
		rot,
		ui_fade(left.color, (0.08 + 0.14 * e_l) * (1 - 0.5 * e_r) * en_l),
		radius = UI_RADIUS * scale,
	)
	hud_rect_rotated(
		mid + half_cx,
		cy + half_cy,
		flood_w,
		flood_h,
		rot,
		ui_fade(right.color, (0.08 + 0.14 * e_r) * (1 - 0.5 * e_l) * en_r),
		radius = UI_RADIUS * scale,
	)

	// 4 -- and the un-hovered one falls back toward the background
	hud_rect_rotated(
		mid - half_cx,
		cy - half_cy,
		flood_w,
		flood_h,
		rot,
		ui_fade(UI_BG, 0.5 * e_r),
		radius = UI_RADIUS * scale,
	)
	hud_rect_rotated(
		mid + half_cx,
		cy + half_cy,
		flood_w,
		flood_h,
		rot,
		ui_fade(UI_BG, 0.5 * e_l),
		radius = UI_RADIUS * scale,
	)

	// 5 -- a wash creeping in from the outer edge of the hovered half
	hud_rect_gradient(0, 0, width * 0.45, height, ui_fade(left.color, 0.12 * e_l))
	hud_rect_gradient(
		width * 0.55,
		0,
		width * 0.45,
		height,
		ui_fade(right.color, 0.12 * e_r),
		flip = true,
	)

	// 6 -- the frame line along the top, meeting where the divider starts
	div_top := div_rest(width, height, skew, 0) + (mid - width * 0.5)
	rule_h := 3 * scale
	hud_rect(0, 0, div_top, rule_h, ui_fade(left.color, (0.35 + 0.65 * e_l) * en_l))
	hud_rect(div_top, 0, width - div_top, rule_h, ui_fade(right.color, (0.35 + 0.65 * e_r) * en_r))

	// 7 -- the divider itself, tinted by whichever half leads
	div_color := ui_fade(UI_STROKE, 0.9)
	if e_l >= e_r {
		div_color = ui_mix(div_color, left.color, e_l)
	} else {
		div_color = ui_mix(div_color, right.color, e_r)
	}
	hud_rect_rotated(
		mid,
		cy,
		2 * scale,
		height * 1.1 * div_enter,
		rot,
		div_color,
		radius = 1 * scale,
	)
	notch := 8 * scale * div_enter
	hud_rect_rotated(mid, cy, notch, notch, rot + math.PI * 0.25, div_color)

	// 8, 9 -- the content of each half
	draw_split_half(width * 0.26 + dx_l, width, height, left, e_l, e_r, en_l, age)
	draw_split_half(width * 0.74 + dx_r, width, height, right, e_r, e_l, en_r, age)

	// 10 -- the title, a letter-spaced eyebrow between two rules
	title_dy, title_a := ui_entrance(0)
	title_size := hud_font_size(18 * scale)
	title_y := height * 0.055 + title_dy
	hud_text(
		width * 0.5,
		title_y,
		title,
		title_size,
		ui_fade(UI_TEXT, title_a),
		.Center,
		tracking = title_size * 0.35,
	)
	title_w := hud_text_width(title, title_size, tracking = title_size * 0.35)
	rule_y := title_y + title_size * 0.5
	rule_w := 28 * scale
	rule_gap := title_w * 0.5 + 16 * scale
	hud_rect(
		width * 0.5 - rule_gap - rule_w,
		rule_y,
		rule_w,
		1 * scale,
		ui_fade(UI_TEXT_FAINT, title_a),
	)
	hud_rect(width * 0.5 + rule_gap, rule_y, rule_w, 1 * scale, ui_fade(UI_TEXT_FAINT, title_a))

	// 11 -- the handshake, while the roster is still on its way
	if connecting {
		status_size := hud_font_size(UI_MICRO * scale)
		status_y := height * 0.115
		hud_text(
			width * 0.5,
			status_y,
			"CONNECTING",
			status_size,
			ui_fade(UI_TEXT_FAINT, title_a),
			.Center,
			tracking = status_size * 0.30,
		)
		bar_w := 140 * scale
		seg := 40 * scale
		bar_y := status_y + status_size + 10 * scale
		phase := f32(math.mod(glfw.GetTime(), 2.4)) / 2.4
		sweep := ease_in_out_cubic(1 - abs(2 * phase - 1))
		hud_rect(
			width * 0.5 - bar_w * 0.5,
			bar_y,
			bar_w,
			2 * scale,
			ui_fade(UI_STROKE, 0.8 * title_a),
		)
		hud_rect(
			width * 0.5 - bar_w * 0.5 + (bar_w - seg) * sweep,
			bar_y,
			seg,
			2 * scale,
			ui_fade(UI_ACCENT, title_a),
		)
	}

	// 12 -- BACK, with the same growing underline the ghost buttons use
	back_a := clamp((age - 0.25) / 0.25, 0, 1)
	back_size := hud_font_size(UI_LABEL * scale)
	hud_text(
		width * 0.5,
		back_y + (back_h - back_size) * 0.5,
		"BACK",
		back_size,
		ui_fade(ui_mix(UI_TEXT_DIM, UI_TEXT, back_t), back_a),
		.Center,
		tracking = back_size * 0.25,
	)
	uw := 100 * scale * ease_out_cubic(back_t)
	if uw > 1 {
		hud_rect(
			width * 0.5 - uw * 0.5,
			back_y + back_h - 2 * scale,
			uw,
			2 * scale,
			ui_fade(UI_ACCENT, back_a),
		)
	}

	if ui_clicked(back_hover) do return .None, true
	if ui_clicked(hov_l) do return .Left, false
	if ui_clicked(hov_r) do return .Right, false
	return .None, false
}

// One half's content column, centred on cx. `self` is this half's eased hover,
// `other` the opposite one's -- everything recedes as the other side takes over.
@(private = "file")
draw_split_half :: proc(cx, width, height: f32, half: Split_Half, self, other, enter, age: f32) {
	scale := hud_scale()
	content_a := (1 - 0.65 * other) * enter * (half.disabled ? 0.45 : 1)
	if content_a <= 0.002 do return

	tag_color := ui_mix(half.color, UI_TEXT_FAINT, 0.6 * other + (half.disabled ? 0.5 : 0))

	// the tag grows about its own centre on hover
	base_size := hud_font_size(110 * scale)
	tag_size := hud_font_size(110 * scale * (1 + 0.04 * self))
	tag_y := height * 0.30 - (tag_size - base_size) * 0.5
	hud_text_shadow(cx, tag_y, half.tag, tag_size, ui_fade(tag_color, content_a), .Center)

	rule_y := height * 0.30 + 128 * scale
	rule_w := max(56 * scale, hud_text_width(half.tag, tag_size) * (0.4 + 0.6 * self))
	hud_rect(cx - rule_w * 0.5, rule_y, rule_w, 3 * scale, ui_fade(half.color, content_a))

	sub_size := hud_font_size(UI_BODY * scale)
	hud_text(
		cx,
		rule_y + 19 * scale,
		half.subtitle,
		sub_size,
		ui_fade(ui_mix(UI_TEXT_DIM, UI_TEXT, self), content_a),
		.Center,
		tracking = sub_size * (0.18 + 0.10 * self),
	)

	line_size := hud_font_size(UI_LABEL * scale)
	line_y := rule_y + 19 * scale + 36 * scale
	for line in half.lines {
		if line == "" do continue
		hud_text(
			cx,
			line_y,
			line,
			line_size,
			ui_fade(UI_TEXT_FAINT, content_a),
			.Center,
			tracking = line_size * 0.20,
		)
		line_y += 24 * scale
	}

	if half.slot_cap > 0 {
		draw_split_roster(cx, width, height, half, content_a, age)
	}

	// the call to action, or the reason there is none
	hint_size := hud_font_size(UI_LABEL * scale)
	if half.disabled {
		hud_text(
			cx,
			height * 0.80,
			half.disabled_note,
			hint_size,
			ui_fade(UI_TEXT_FAINT, content_a),
			.Center,
			tracking = hint_size * 0.30,
		)
	} else if half.hint != "" {
		hud_text(
			cx,
			height * 0.80,
			half.hint,
			hint_size,
			ui_fade(half.color, self * content_a),
			.Center,
			tracking = hint_size * 0.30,
		)
	}
}

// The lineup table: filled rows are solid, open seats are hollow, and the
// local player keeps the accent bar the scoreboard marks them with.
@(private = "file")
draw_split_roster :: proc(cx, width, height: f32, half: Split_Half, content_a, age: f32) {
	scale := hud_scale()
	// capped against the screen so a narrow window never runs it into the divider
	w := min(360 * scale, width * 0.34)
	x := cx - w * 0.5
	y := height * 0.52
	row_h := 30 * scale
	gap := 4 * scale

	hud_rect(x, y, w, 2 * scale, ui_fade(half.color, content_a))
	y += 10 * scale

	name_size := hud_font_size(UI_LABEL * scale)
	chip_size := hud_font_size(UI_MICRO * scale)

	rows := min(half.slot_cap, SELECT_ROSTER_ROWS)
	for i in 0 ..< rows {
		row_e := ease_out_cubic(clamp((age - 0.20 - f32(i) * 0.03) / 0.22, 0, 1))
		alpha := content_a * row_e
		ry := y + f32(i) * (row_h + gap) + (1 - row_e) * 10 * scale
		if alpha <= 0.002 do continue

		if i >= len(half.slots) {
			hud_frame(x, ry, w, row_h, UI_STROKE_W * scale, ui_fade(UI_STROKE, 0.7 * alpha))
			hud_text(
				x + 12 * scale,
				ry + (row_h - chip_size) * 0.5,
				"OPEN SLOT",
				chip_size,
				ui_fade(UI_TEXT_FAINT, 0.8 * alpha),
				tracking = chip_size * 0.20,
			)
			continue
		}

		slot := half.slots[i]
		hud_rect(x, ry, w, row_h, ui_fade(slot.local ? UI_PANEL_RAISED : UI_PANEL, alpha))
		if slot.local {
			hud_rect(x, ry, 2 * scale, row_h, ui_fade(UI_ACCENT, alpha))
		}
		hud_text(
			x + 12 * scale,
			ry + (row_h - name_size) * 0.5,
			slot.name,
			name_size,
			ui_fade(slot.local ? UI_TEXT : UI_TEXT_DIM, alpha),
		)
		chip := slot.local ? "YOU" : (slot.bot ? "BOT" : "")
		if chip != "" {
			hud_text(
				x + w - 10 * scale,
				ry + (row_h - chip_size) * 0.5,
				chip,
				chip_size,
				ui_fade(slot.local ? UI_ACCENT : UI_TEXT_FAINT, alpha),
				.Right,
				tracking = chip_size * 0.20,
			)
		}
	}

	if len(half.slots) > rows {
		hud_text(
			x + 12 * scale,
			y + f32(rows) * (row_h + gap) + 4 * scale,
			fmt.tprintf("PLUS {} MORE", len(half.slots) - rows),
			chip_size,
			ui_fade(UI_TEXT_FAINT, content_a),
			tracking = chip_size * 0.20,
		)
	}
}

// -------------------------------------------------------------------- roster

Select_Roster :: struct {
	slots:      [game.Team][game.MAX_PAWNS]Select_Slot,
	filled:     [game.Team]int, // rows to draw
	humans:     [game.Team]int, // what the server balances against
	connecting: bool, // handshake still in flight
}

// The same two sources the scoreboard merges: the snapshot decides who exists
// and on which side, the roster message supplies the names.
gather_select_roster :: proc() -> Select_Roster {
	r: Select_Roster

	if strings.has_prefix(cli.hudpreview, "teamselect") {
		// The preview never connects, so a hand-built lineup stands in --
		// asymmetric on purpose, so one screenshot shows every row state.
		seed_t := []Select_Slot {
			{name = "YOU", local = true},
			{name = "RIPTIDE"},
			{name = "BOT 04", bot = true},
			{name = "BOT 05", bot = true},
		}
		seed_ct := []Select_Slot {
			{name = "NOVA"},
			{name = "BOT 08", bot = true},
			{name = "BOT 09", bot = true},
		}
		for slot, i in seed_t do r.slots[.T][i] = slot
		for slot, i in seed_ct do r.slots[.CT][i] = slot
		r.filled = {
			.T  = len(seed_t),
			.CT = len(seed_ct),
		}
		r.humans = {
			.T  = 2,
			.CT = 1,
		}
		return r
	}

	r.connecting = !net_client.got_accept
	snap := snapshot_at(net_client.latest_tick)
	if snap == nil do return r

	// humans first: a real player outranks the bot that will yield to a join
	for pass in 0 ..< 2 {
		for i in 0 ..< game.MAX_PAWNS {
			if i not_in snap.present do continue
			e := &snap.entities[i]
			bot := .Is_Bot in e.flags
			if bot != (pass == 1) do continue

			team: game.Team = .Team_CT in e.flags ? .CT : .T
			local := i == net_client.pawn_id
			r.slots[team][r.filled[team]] = {
				name  = select_slot_name(i, bot, local),
				bot   = bot,
				local = local,
			}
			r.filled[team] += 1
			if !bot do r.humans[team] += 1
		}
	}
	return r
}

@(private = "file")
select_slot_name :: proc(pawn_id: int, bot, local: bool) -> string {
	if local {
		persona := steam_persona()
		return persona != "" ? persona : "YOU"
	}
	entry := &net_client.roster[pawn_id]
	if entry.known && entry.name_len > 0 {
		return string(entry.name[:entry.name_len])
	}
	if bot do return fmt.tprintf("BOT %02d", pawn_id)
	return fmt.tprintf("PLAYER %02d", pawn_id)
}
