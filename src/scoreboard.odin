package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "game"
import "vendor:glfw"

// The hold-TAB scoreboard: display-only, so it needs no modal bookkeeping --
// it cannot eat clicks or keys, it just draws over the game while held.
// Rows come from the freshest snapshot (team, alive, HP, weapon for every
// pawn); K/D is authoritative for the local player and the killfeed tally
// for everyone else until the roster message replicates real numbers.

scoreboard: struct {
	forced: bool, // the preview harness holds it open
	show_t: f32,
}

@(private = "file")
Scoreboard_Row :: struct {
	id:            int,
	ct:            bool,
	alive:         bool,
	bot:           bool,
	hp:            int,
	weapon:        u8,
	kills, deaths: int,
	local:         bool,
}

scoreboard_visible :: proc() -> bool {
	if scoreboard.forced do return true
	return(
		key_down(glfw.KEY_TAB) &&
		scene_playing() &&
		!scene.paused &&
		!settings_screen.open &&
		!buy_menu.open \
	)
}

@(private = "file")
gather_rows :: proc(rows: ^[dynamic]Scoreboard_Row) {
	if scoreboard.forced && local_sim_active() {
		// the preview has no snapshots; a hand-built 5v5 stands in
		seed := [10]Scoreboard_Row {
			{id = 0, ct = true, alive = true, hp = 87, weapon = 1, kills = 12, deaths = 7, local = true},
			{id = 2, ct = true, alive = true, bot = true, hp = 100, weapon = 2, kills = 9, deaths = 8},
			{id = 3, ct = true, alive = false, bot = true, weapon = 0, kills = 7, deaths = 10},
			{id = 4, ct = true, alive = true, bot = true, hp = 43, weapon = 1, kills = 5, deaths = 9},
			{id = 5, ct = true, alive = false, weapon = 2, kills = 3, deaths = 11},
			{id = 8, alive = true, bot = true, hp = 100, weapon = 2, kills = 14, deaths = 6},
			{id = 9, alive = true, bot = true, hp = 61, weapon = 1, kills = 10, deaths = 7},
			{id = 10, alive = false, bot = true, weapon = 0, kills = 8, deaths = 9},
			{id = 11, alive = true, bot = true, hp = 22, weapon = 2, kills = 6, deaths = 8},
			{id = 12, alive = false, bot = true, weapon = 1, kills = 2, deaths = 12},
		}
		for row in seed do append(rows, row)
		return
	}

	snap := snapshot_at(net_client.latest_tick)
	if snap == nil do return
	for i in 0 ..< game.MAX_PAWNS {
		if i not_in snap.present do continue
		e := &snap.entities[i]
		local := i == net_client.pawn_id

		// the roster is authoritative; the killfeed tally covers the gap
		// until the first one arrives
		kills := local ? player.kills : killfeed.tally[i].kills
		deaths := local ? player.deaths : killfeed.tally[i].deaths
		if net_client.roster[i].known {
			kills = net_client.roster[i].kills
			deaths = net_client.roster[i].deaths
		}

		append(
			rows,
			Scoreboard_Row {
				id = i,
				ct = .Team_CT in e.flags,
				alive = .Alive in e.flags,
				bot = .Is_Bot in e.flags,
				hp = int(e.health),
				weapon = e.weapon,
				kills = kills,
				deaths = deaths,
				local = local,
			},
		)
	}
}

draw_scoreboard :: proc(width, height: f32) {
	target := scoreboard_visible()
	scoreboard.show_t = ui_approach(scoreboard.show_t, target ? 1 : 0, ui.dt, target ? 20 : 30)
	t := scoreboard.show_t
	if t < 0.02 do return

	scale := hud_scale()
	alpha := t

	hud_rect(0, 0, width, height, ui_fade(UI_SCRIM_HEAVY, alpha))

	panel_w := min(1100 * scale, width - 64 * scale)
	panel_h := 640 * scale
	px := (width - panel_w) * 0.5
	py := (height - panel_h) * 0.5 + (1 - ease_out_cubic(t)) * 10 * scale
	pad := 28 * scale

	hud_rect(px, py, panel_w, panel_h, ui_fade(UI_PANEL, alpha))
	hud_frame(px, py, panel_w, panel_h, UI_STROKE_W * scale, ui_fade(UI_STROKE, alpha))

	// header: mode and round left, the big score centre, clock right
	head_size := hud_font_size(UI_LABEL * scale)
	head_y := py + pad
	mode_text :=
		net_client.mode == .Comp \
		? fmt.tprintf("COMPETITIVE - ROUND %d", net_client.round) \
		: "TEAM DEATHMATCH"
	ui_heading(px + pad, head_y, mode_text, head_size, UI_TEXT_DIM)

	seconds := max(int(net_client.time_left), 0)
	hud_text(
		px + panel_w - pad,
		head_y,
		fmt.tprintf("{}:{:02d}", seconds / 60, seconds % 60),
		head_size,
		UI_TEXT_DIM,
		.Right,
	)

	score_size := hud_font_size(UI_H1 * scale)
	score := fmt.tprintf("{} : {}", net_client.t_score, net_client.ct_score)
	score_w := hud_text_width(score, score_size)
	cx := px + panel_w * 0.5
	hud_text(cx, head_y, score, score_size, ui_fade(HUD_WHITE, alpha), .Center)
	hud_text(cx - score_w * 0.5 - 20 * scale, head_y, "T", score_size, ui_fade(MENU_T_COLOR, alpha), .Right)
	hud_text(cx + score_w * 0.5 + 20 * scale, head_y, "CT", score_size, ui_fade(MENU_CT_COLOR, alpha))

	rows := make([dynamic]Scoreboard_Row, 0, game.MAX_PAWNS, context.temp_allocator)
	gather_rows(&rows)
	slice.sort_by(rows[:], proc(a, b: Scoreboard_Row) -> bool {
		if a.ct != b.ct do return !a.ct // stable team split; order fixed below
		return a.kills > b.kills
	})

	own_ct := net_client.team == .CT
	y := py + pad + UI_H1 * scale + 28 * scale
	y = draw_team_block(px + pad, y, panel_w - 2 * pad, own_ct, rows[:], alpha, t)
	y += 18 * scale
	draw_team_block(px + pad, y, panel_w - 2 * pad, !own_ct, rows[:], alpha, t)
}

@(private = "file")
draw_team_block :: proc(x, y, w: f32, ct: bool, rows: []Scoreboard_Row, alpha, show_t: f32) -> f32 {
	scale := hud_scale()
	color := ct ? MENU_CT_COLOR : MENU_T_COLOR

	// the team header: a coloured rule, the role, the alive count
	alive := 0
	total := 0
	for row in rows {
		if row.ct != ct do continue
		total += 1
		if row.alive do alive += 1
	}

	hud_rect(x, y, w, 2 * scale, ui_fade(color, alpha))
	head_size := hud_font_size(UI_LABEL * scale)
	head_y := y + 8 * scale
	ui_heading(x, head_y, ct ? "DEFENDERS" : "ATTACKERS", head_size, ui_fade(color, alpha))
	hud_text(
		x + w,
		head_y,
		fmt.tprintf("{} OF {} ALIVE", alive, total),
		head_size,
		ui_fade(UI_TEXT_FAINT, alpha),
		.Right,
	)

	// column headers
	col_size := hud_font_size(UI_MICRO * scale)
	col_y := head_y + head_size + 10 * scale
	hp_x := x + w - 150 * scale
	k_x := x + w - 80 * scale
	d_x := x + w - 30 * scale
	wpn_x := x + w - 280 * scale
	hud_text(x + 22 * scale, col_y, "PLAYER", col_size, ui_fade(UI_TEXT_FAINT, alpha))
	hud_text(wpn_x, col_y, "WEAPON", col_size, ui_fade(UI_TEXT_FAINT, alpha))
	hud_text(hp_x, col_y, "HP", col_size, ui_fade(UI_TEXT_FAINT, alpha), .Right)
	hud_text(k_x, col_y, "K", col_size, ui_fade(UI_TEXT_FAINT, alpha), .Right)
	hud_text(d_x, col_y, "D", col_size, ui_fade(UI_TEXT_FAINT, alpha), .Right)

	row_h := 34 * scale
	row_size := hud_font_size(UI_LABEL * scale)
	ry := col_y + col_size + 8 * scale

	index := 0
	for row in rows {
		if row.ct != ct do continue

		// rows trail the panel in slightly, top to bottom
		row_t := clamp((show_t - f32(index) * 0.03) / 0.7, 0, 1)
		row_alpha := alpha * row_t * (row.alive ? 1 : 0.4)

		if row.local {
			hud_rect(x, ry, w, row_h, ui_fade(UI_PANEL_RAISED, row_alpha))
			hud_rect(x, ry, 2 * scale, row_h, ui_fade(UI_ACCENT, row_alpha))
		}

		ty := ry + (row_h - row_size) * 0.5

		// the alive dot
		dot := 6 * scale
		dot_y := ry + (row_h - dot) * 0.5
		if row.alive {
			hud_rect(x + 8 * scale, dot_y, dot, dot, ui_fade(color, row_alpha))
		} else {
			hud_frame(x + 8 * scale, dot_y, dot, dot, UI_STROKE_W * scale, ui_fade(UI_TEXT_FAINT, row_alpha))
		}

		name := scoreboard_name(row)
		hud_text(x + 22 * scale, ty, name, row_size, ui_fade(row.local ? HUD_WHITE : UI_TEXT_DIM, row_alpha))

		if int(row.weapon) < game.WEAPON_COUNT && row.alive {
			hud_text(
				wpn_x,
				ty,
				strings.to_upper(game.WEAPONS[row.weapon].name, context.temp_allocator),
				hud_font_size(UI_MICRO * scale),
				ui_fade(UI_TEXT_FAINT, row_alpha),
			)
		}
		if row.alive {
			hud_text(hp_x, ty, fmt.tprintf("{}", row.hp), row_size, ui_fade(UI_TEXT_DIM, row_alpha), .Right)
		}
		hud_text(k_x, ty, fmt.tprintf("{}", row.kills), row_size, ui_fade(HUD_WHITE, row_alpha), .Right)
		hud_text(d_x, ty, fmt.tprintf("{}", row.deaths), row_size, ui_fade(UI_TEXT_DIM, row_alpha), .Right)

		ry += row_h + 2 * scale
		index += 1
	}
	return ry
}

@(private = "file")
scoreboard_name :: proc(row: Scoreboard_Row) -> string {
	if row.local {
		persona := steam_persona()
		return persona != "" ? persona : "YOU"
	}
	entry := &net_client.roster[row.id]
	if entry.known && entry.name_len > 0 {
		return string(entry.name[:entry.name_len])
	}
	if row.bot do return fmt.tprintf("BOT %02d", row.id)
	return fmt.tprintf("PLAYER %02d", row.id)
}
