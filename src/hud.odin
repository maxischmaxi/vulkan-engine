package main

import "core:fmt"
import "core:math"
import "core:strings"
import "game"
import "vendor:glfw"

// What the HUD says. hud_render.odin knows how to put a rectangle on screen and
// nothing about what it means; everything here is the other half -- it reads
// gameplay state and turns it into rectangles, once per frame, keeping none.
//
// Layout is written in reference pixels against a 1080-tall screen and scaled
// from there, the same trick the crosshair uses against 480. A HUD authored in
// raw pixels is either a postage stamp at 4K or covers half a 900p window.

HUD_REFERENCE_HEIGHT :: f32(1080)

HUD_MARGIN :: f32(24)
HUD_MINIMAP_SIZE :: f32(190)

HUD_TEXT_BIG :: f32(40)
HUD_TEXT_MEDIUM :: f32(24)
HUD_TEXT_SMALL :: f32(16)

// Colors live in theme.odin; the HUD names roles, not values.

// Below this the health readout starts pulsing, the way every shooter since
// Doom has warned that the next hit is the last one.
HUD_LOW_HEALTH :: 25

// The weapon slots' outer height, in reference pixels. Shared because the
// speedometer sits directly above them and the two must not overlap.
HUD_SLOT_HEIGHT :: HUD_TEXT_SMALL + 2 * 8

Hud :: struct {
	visible:          bool,
	// The weapon-slot underline eases toward the active slot instead of
	// jumping.
	slot_ux, slot_uw: f32,
	// Value-change motion: short timers armed on the frame a number moves.
	prev_health:      int,
	health_flash:     f32,
	prev_money:       int,
	money_seen:       bool,
	money_pop:        f32,
	money_delta:      int,
	money_delta_t:    f32,
	prev_mag:         int,
	mag_pop:          f32,
	prev_respawn:     int,
	respawn_pop:      f32,
	death_t:          f32, // the overlay's fade-in
}

hud := Hud {
	visible = true,
}

hud_scale :: proc() -> f32 {
	return max(0.5, f32(g.swapchain_extent.height) / HUD_REFERENCE_HEIGHT) * game_settings.hud_scale
}

// Called from build_frame, once the simulation for this frame is settled.
build_hud :: proc() {
	// Not a debug tool: hiding the overlay for a screenshot is something a
	// shipped build should be able to do too.
	if key_pressed(glfw.KEY_F12) do hud.visible = !hud.visible

	hud_preview_apply()
	update_minimap(game.clock.frame_dt)

	hud_begin_frame()
	defer hud_end_frame()

	// Ticks screen age and the scene transition; may fire enter_scene at the
	// fade midpoint, so it runs before any screen reads scene.current.
	ui_frame_begin()

	// A minimised window has a zero extent, and every layout number below would
	// come out as zero or a division by it.
	if g.swapchain_extent.width == 0 || g.swapchain_extent.height == 0 do return

	scale := hud_scale()
	width := f32(g.swapchain_extent.width)
	height := f32(g.swapchain_extent.height)
	margin := HUD_MARGIN * scale

	// LIFO with the hud_end_frame defer above: the scrim draws last, over
	// every path out of this proc, including the menu early return.
	defer ui_draw_transition_scrim(width, height)

	// Every screen that is not gameplay draws itself and nothing of the HUD.
	// Settings replaces the screen under it entirely: immediate-mode buttons
	// underneath would still eat clicks at their coordinates.
	if !scene_playing() {
		if settings_screen.open {
			draw_settings_screen()
			return
		}
		draw_scene_screens(width, height)
		return
	}

	// Under the HUD and outside the F12 gate, like the crosshair it replaces.
	if weapon_state.zoom_active do draw_scope(width, height)

	if hud.visible {
		// The first quarter second after entering play, the top group slides
		// down and the bottom group slides up into place.
		top_dy, _ := ui_entrance(0)
		bot_dy, _ := ui_entrance(2)

		draw_minimap(margin, margin - top_dy * 0.5, HUD_MINIMAP_SIZE * scale)
		if competitive_active() {
			// The top bar replaces draw_status wholesale: clock, score and
			// alive state live up there.
			draw_topbar(width, margin - top_dy * 0.5)
		} else {
			draw_status(width, margin - top_dy * 0.5)
		}
		// Under the debug panel when the tools are up -- both want top right.
		killfeed_top := margin + (debug_active() ? 300 * scale : 0)
		draw_killfeed(width - margin, killfeed_top)
		draw_health(margin, height - margin + bot_dy)
		draw_ammo(width - margin, height - margin + bot_dy)
		draw_slots(width * 0.5, height - margin + bot_dy)
		draw_speed(width * 0.5, height - margin - HUD_SLOT_HEIGHT * scale + bot_dy)
		draw_weapon_prompt(width * 0.5, height * 0.5)

		if competitive_active() {
			draw_round_hud(width, height)
			draw_bomb_hud(width, height)
			draw_money(margin, height - margin)
		}

		if debug_active() do draw_debug_panel(width - margin, margin)
		if player.alive do hud.death_t = 0
		if !player.alive do draw_death_overlay(width, height)
	}

	if !local_sim_active() && net_client.phase == .Countdown {
		draw_countdown(width, height)
	}

	// After every submitter: one winner per band, shared motion.
	draw_banners(width, height)

	// Display-only, over the HUD and under the pause/settings modals.
	draw_scoreboard(width, height)

	// The pause overlay outlives F12: its buttons must stay reachable, and so
	// must the buy menu's rows. It hides while settings sits on top, again so
	// its buttons cannot eat the settings screen's clicks.
	if scene.paused && !settings_screen.open do draw_pause_overlay(width, height)
	draw_buy_menu(width, height)

	// Last, so it sits over everything -- it is modal while it is open.
	draw_settings_screen()
}

// The scope: black bars boxing a centred circle-less square, a hairline cross
// where the render pass's crosshair would be. Quads only.
@(private = "file")
draw_scope :: proc(width, height: f32) {
	scale := hud_scale()
	view := min(width, height)
	half := view * 0.5
	cx := width * 0.5
	cy := height * 0.5

	black := [4]f32{0, 0, 0, 1}
	if cx - half > 0 {
		hud_rect(0, 0, cx - half, height, black)
		hud_rect(cx + half, 0, width - (cx + half), height, black)
	}
	if cy - half > 0 {
		hud_rect(cx - half, 0, view, cy - half, black)
		hud_rect(cx - half, cy + half, view, height - (cy + half), black)
	}

	line := max(1, 1 * scale)
	hud_rect(cx - half, cy - line * 0.5, view, line, {0, 0, 0, 0.9})
	hud_rect(cx - line * 0.5, cy - half, line, view, {0, 0, 0, 0.9})
}

// ------------------------------------------------------------------- panels

// Top centre: the match clock, the team score, how the player is doing. In
// the benchmark there is no match, so the session clock stands in.
@(private = "file")
draw_status :: proc(width, margin: f32) {
	scale := hud_scale()
	center := width * 0.5

	seconds := int(f32(game.clock.tick_count) * game.TICK_DT)
	if !local_sim_active() {
		seconds = int(math.ceil(net_client.time_left))
	}
	timer := fmt.tprintf("{}:{:02d}", seconds / 60, seconds % 60)

	y := margin
	hud_text_shadow(center, y, timer, HUD_TEXT_MEDIUM * scale, HUD_WHITE, .Center)
	y += HUD_TEXT_MEDIUM * scale + 6 * scale

	if practice_active() {
		hud_text_shadow(center, y, "PRACTICE", HUD_TEXT_SMALL * scale, HUD_DIM, .Center)
		y += HUD_TEXT_SMALL * scale + 8 * scale
	} else if !bench_active() {
		// T left, CT right, each in its team colour; the underline marks the
		// player's own side.
		score := fmt.tprintf("{} : {}", net_client.t_score, net_client.ct_score)
		size := HUD_TEXT_SMALL * scale
		score_w := hud_text_width(score, size)
		hud_text_shadow(center, y, score, size, HUD_WHITE, .Center)
		t_end := hud_text_shadow(
			center - score_w * 0.5 - 14 * scale,
			y,
			"T",
			size,
			MENU_T_COLOR,
			.Right,
		)
		ct_end := hud_text_shadow(
			center + score_w * 0.5 + 14 * scale,
			y,
			"CT",
			size,
			MENU_CT_COLOR,
		)
		underline_w := 12 * scale
		underline_x := scene.chosen_team == .T ? t_end - underline_w : ct_end - 2 * underline_w
		hud_rect(
			underline_x,
			y + size + 2 * scale,
			underline_w * (scene.chosen_team == .T ? 1 : 2),
			2 * scale,
			HUD_DIM,
		)
		y += size + 8 * scale
	}

	hud_text_shadow(
		center,
		y,
		fmt.tprintf("{} KILLS   {} DEATHS", player.kills, player.deaths),
		HUD_TEXT_SMALL * scale,
		HUD_DIM,
		.Center,
	)

	y += HUD_TEXT_SMALL * scale + 4 * scale
	enemies := local_sim_active() ? bots_alive() : remote_enemies_alive()
	hud_text_shadow(
		center,
		y,
		fmt.tprintf(practice_active() ? "{} TARGETS" : "{} ENEMIES", enemies),
		HUD_TEXT_SMALL * scale,
		HUD_FAINT,
		.Center,
	)
}

// Centre screen while the server counts the match in.
@(private = "file")
draw_countdown :: proc(width, height: f32) {
	_ = width
	_ = height
	seconds := max(int(math.ceil(net_client.time_left)), 0)
	banner_submit(
		.Headline,
		{head = fmt.tprintf("MATCH STARTS IN {}", seconds), color = HUD_WARN, priority = 50},
	)
}

// The bottom-left block's total height in reference pixels: bar, number and
// label. Money stacks above it through this one number, so the two cannot
// drift into each other again.
HUD_HEALTH_BLOCK :: f32(64)

// The balance, stacked above the health block in the same corner CS keeps
// it. Warmup shows INF because the glyph set has no infinity.
@(private = "file")
draw_money :: proc(x, bottom: f32) {
	scale := hud_scale()
	money_y := bottom - (HUD_HEALTH_BLOCK + 18) * scale - UI_BODY * scale

	money := int(net_client.money)
	if hud.money_seen && money != hud.prev_money {
		hud.money_delta = money - hud.prev_money
		hud.money_delta_t = 0.5
		hud.money_pop = 0.15
	}
	hud.prev_money = money
	hud.money_seen = true
	hud.money_pop = max(hud.money_pop - ui.dt, 0)
	hud.money_delta_t = max(hud.money_delta_t - ui.dt, 0)

	size := UI_BODY * scale * (1 + 0.08 * hud.money_pop / 0.15)
	text := net_client.phase == .Warmup ? "$INF" : fmt.tprintf("$%d", money)
	pen := hud_text_shadow(x, money_y, text, size, HUD_GOOD)

	// the delta ticker: rises and fades beside the balance
	if hud.money_delta_t > 0 && hud.money_delta != 0 {
		t := hud.money_delta_t / 0.5
		delta_color := hud.money_delta > 0 ? HUD_GOOD : HUD_BAD
		hud_text(
			pen + 10 * scale,
			money_y - (1 - t) * 14 * scale,
			fmt.tprintf("%+d", hud.money_delta),
			UI_LABEL * scale,
			ui_fade(delta_color, t),
		)
	}
}

// Bottom left, counter-strike's corner for it: a letter-spaced label over the
// big number over a thin bar. The bar carries the urgency -- it pulses when
// low -- so the number itself stays readable.
@(private = "file")
draw_health :: proc(x, bottom: f32) {
	scale := hud_scale()
	bar_w := 140 * scale
	bar_h := 3 * scale
	bar_y := bottom - bar_h
	num_size := hud_font_size(UI_H2 * scale)
	num_y := bar_y - 6 * scale - num_size
	label_size := hud_font_size(UI_LABEL * scale)
	label_y := num_y - label_size - 4 * scale

	health := max(player.health, 0)
	if health < hud.prev_health do hud.health_flash = 0.2
	hud.prev_health = health
	hud.health_flash = max(hud.health_flash - ui.dt, 0)
	flash := hud.health_flash / 0.2

	color := UI_TEXT
	if health <= HUD_LOW_HEALTH {
		color = UI_BAD
	} else if health <= 50 {
		color = UI_WARN
	}
	color = ui_mix(color, UI_ACCENT, flash * 0.8)
	num_size *= 1 + 0.06 * flash

	bar_alpha := f32(1)
	if health <= HUD_LOW_HEALTH {
		// Sine rather than a square blink: a hard flash at the moment you most
		// need to read the number is the wrong kind of urgent.
		bar_alpha = 0.65 + 0.35 * math.sin(f32(game.clock.tick_count) * game.TICK_DT * 9)
	}

	ui_heading(x, label_y, "HP", label_size, UI_TEXT_FAINT)
	hud_text_shadow(x, num_y, fmt.tprintf("{}", health), num_size, color)
	hud_rect(x, bar_y, bar_w, bar_h, ui_fade(UI_STROKE, 0.8))
	hud_rect(x, bar_y, bar_w * clamp(f32(health) / 100, 0, 1), bar_h, ui_fade(color, bar_alpha))

	if player.armor <= 0 do return

	ax := x + 96 * scale
	ui_heading(ax, label_y, "ARMOR", label_size, UI_TEXT_FAINT)
	hud_text_shadow(
		ax,
		num_y + num_size - UI_BODY * scale,
		fmt.tprintf("{}", player.armor),
		UI_BODY * scale,
		UI_TEXT_DIM,
	)
}

// Bottom right: magazine over reserve, with the weapon named above them. A melee
// weapon has neither, so it says so instead of showing two zeroes.
@(private = "file")
draw_ammo :: proc(right, bottom: f32) {
	scale := hud_scale()
	weapon := current_weapon()

	name_size := hud_font_size(UI_LABEL * scale)
	name_y := bottom - HUD_TEXT_BIG * scale - name_size - 8 * scale
	hud_text_shadow(
		right,
		name_y,
		strings.to_upper(weapon.name, context.temp_allocator),
		name_size,
		HUD_DIM,
		.Right,
		tracking = name_size * 0.12,
	)

	value_y := bottom - HUD_TEXT_BIG * scale

	if weapon.melee {
		hud_text_shadow(right, value_y, "MELEE", HUD_TEXT_BIG * scale, HUD_DIM, .Right)
		return
	}

	ammo := current_ammo()

	// The reserve is dimmer and smaller than the magazine: what matters in a
	// firefight is how many rounds are left before the reload, not after it.
	reserve := fmt.tprintf("/ {}", ammo.reserve)
	reserve_width := hud_text_width(reserve, UI_BODY * scale)
	reserve_color := ammo.reserve <= 0 ? HUD_BAD : HUD_FAINT

	// Sits on the baseline of the magazine number rather than its top.
	hud_text_shadow(
		right,
		value_y + (HUD_TEXT_BIG - UI_BODY) * scale,
		reserve,
		UI_BODY * scale,
		reserve_color,
		.Right,
	)

	// a filled magazine pops once, the moment the reload lands
	if ammo.mag > hud.prev_mag do hud.mag_pop = 0.15
	hud.prev_mag = ammo.mag
	hud.mag_pop = max(hud.mag_pop - ui.dt, 0)

	mag_color := HUD_WHITE
	if ammo.mag <= 0 {
		mag_color = HUD_BAD
	} else if ammo.mag <= weapon.mag_size / 4 {
		mag_color = HUD_WARN
	}

	hud_text_shadow(
		right - reserve_width - 12 * scale,
		value_y,
		fmt.tprintf("{}", ammo.mag),
		HUD_TEXT_BIG * scale * (1 + 0.08 * hud.mag_pop / 0.15),
		mag_color,
		.Right,
	)
}

// Bottom centre: every slot the loadout offers, occupied or not, with the key
// that draws it. Empty slots stay visible so the loadout has a visible shape.
@(private = "file")
draw_slots :: proc(center, bottom: f32) {
	scale := hud_scale()
	size := HUD_TEXT_SMALL * scale
	pad := 8 * scale
	gap := 6 * scale
	height := size + 2 * pad

	labels: [game.WEAPON_SLOTS]string
	widths: [game.WEAPON_SLOTS]f32
	total: f32

	for slot in 0 ..< game.WEAPON_SLOTS {
		index := game.loadout_weapon_in_slot(player.loadout, slot)
		labels[slot] =
			index >= 0 \
			? fmt.tprintf(
					"{} {}",
					slot + 1,
					strings.to_upper(game.WEAPONS[index].name, context.temp_allocator),
				) \
			: fmt.tprintf("{}", slot + 1)
		widths[slot] = hud_text_width(labels[slot], size) + 2 * pad
		total += widths[slot]
	}
	total += gap * f32(game.WEAPON_SLOTS - 1)

	x := center - total * 0.5
	y := bottom - height

	target_x, target_w: f32
	for slot in 0 ..< game.WEAPON_SLOTS {
		index := game.loadout_weapon_in_slot(player.loadout, slot)
		active := index == weapon_state.index

		// flat row, no pill: the sliding underline below carries the state
		text_color := HUD_FAINT
		if active {
			text_color = HUD_WHITE
		} else if index >= 0 {
			text_color = HUD_DIM
		}
		if index < 0 do text_color = ui_fade(HUD_FAINT, 0.5)

		hud_text_shadow(x + widths[slot] * 0.5, y + pad, labels[slot], size, text_color, .Center)

		if active {
			target_x = x
			target_w = widths[slot]
		}
		x += widths[slot] + gap
	}

	// the underline slides between slots rather than jumping
	if hud.slot_uw <= 0 {
		hud.slot_ux, hud.slot_uw = target_x, target_w
	}
	hud.slot_ux = ui_approach(hud.slot_ux, target_x, ui.dt, 22)
	hud.slot_uw = ui_approach(hud.slot_uw, target_w, ui.dt, 22)
	hud_rect(hud.slot_ux + 4 * scale, bottom - 2 * scale, hud.slot_uw - 8 * scale, 2 * scale, HUD_WHITE)
}

// Bottom centre, above the slots: how fast the player is actually travelling.
//
// Not a debug readout. A movement game where speed is something you build has to
// show it, or the difference between a hop that gained and one that did not is
// invisible -- and gaining is the entire feedback loop. Quoted in Source units a
// second, because 250 is a number a counter-strike player already knows the feel
// of, and the metric equivalent is 6.35.
@(private = "file")
draw_speed :: proc(center_x, bottom: f32) {
	scale := hud_scale()
	speed := player_speed_units()

	// Grey while walking, white once running, green once the air has given you
	// something the ground never would.
	color := HUD_FAINT
	if speed > game.WALK_SPEED * game.UNITS_PER_METRE + 12 {
		color = HUD_GOOD
	} else if speed > game.WALK_SPEED * game.UNITS_PER_METRE * 0.5 {
		color = HUD_DIM
	}

	value := fmt.tprintf("{}", int(speed))
	size := HUD_TEXT_MEDIUM * scale
	unit_size := HUD_TEXT_SMALL * scale
	gap := 5 * scale

	// Centred as one block, so the number growing a digit does not shift the
	// label out from under the crosshair.
	total := hud_text_width(value, size) + gap + hud_text_width("u/s", unit_size)
	x := center_x - total * 0.5
	y := bottom - size - 6 * scale

	hud_text_shadow(x, y, value, size, color)
	hud_text_shadow(
		x + total - hud_text_width("u/s", unit_size),
		y + size - unit_size,
		"u/s",
		unit_size,
		HUD_FAINT,
	)
}

// Just under the crosshair, where the eye already is: what the weapon is doing
// when it is not shooting.
@(private = "file")
draw_weapon_prompt :: proc(center_x, center_y: f32) {
	_ = center_x
	_ = center_y
	weapon := current_weapon()

	progress := reload_progress()
	if progress > 0 {
		banner_submit(
			.Action,
			{
				head = "RELOADING",
				color = HUD_WHITE,
				priority = 50,
				progress = progress,
				progress_color = HUD_WHITE,
			},
		)
		return
	}

	if weapon.melee do return

	ammo := current_ammo()
	if ammo.mag > 0 do return

	prompt := ammo.reserve > 0 ? "PRESS R TO RELOAD" : "OUT OF AMMO"
	banner_submit(.Action, {head = prompt, color = HUD_BAD, priority = 40})
}

@(private = "file")
draw_death_overlay :: proc(width, height: f32) {
	scale := hud_scale()

	// fades in over a quarter second instead of slamming shut
	hud.death_t = min(hud.death_t + ui.dt, 0.25)
	t := ease_out_cubic(hud.death_t / 0.25)

	hud_rect(0, 0, width, height, ui_fade(UI_SCRIM_MED, t))

	center_x := width * 0.5
	y := height * 0.5 - UI_H1 * scale + (1 - t) * -10 * scale

	size := hud_font_size(UI_H1 * scale)
	hud_text_shadow(center_x, y, "ELIMINATED", size, ui_fade(HUD_BAD, t), .Center, tracking = size * 0.14)

	// Ceiling, so the last visible number is 1 rather than 0; each new second
	// lands with a small pop.
	remaining := int(math.ceil(max(player.respawn_in, 0)))
	if remaining != hud.prev_respawn do hud.respawn_pop = 0.15
	hud.prev_respawn = remaining
	hud.respawn_pop = max(hud.respawn_pop - ui.dt, 0)

	hud_text_shadow(
		center_x,
		y + UI_H1 * scale + 16 * scale,
		fmt.tprintf("RESPAWNING IN {}", remaining),
		HUD_TEXT_MEDIUM * scale * (1 + 0.08 * hud.respawn_pop / 0.15),
		ui_fade(HUD_DIM, t),
		.Center,
	)
}

// Top right, the only corner nothing else wants. Every shortcut comes from
// DEBUG_ACTIONS, so a tool cannot exist without being listed here.
@(private = "file")
draw_debug_panel :: proc(right, top: f32) {
	scale := hud_scale()
	size := HUD_TEXT_SMALL * scale
	line := size + 5 * scale
	pad := 10 * scale

	lines := make([dynamic]string, 0, len(DEBUG_ACTIONS) + 4, context.temp_allocator)
	append(&lines, "DEBUG")
	append(&lines, fmt.tprintf("{} FPS", int(debug.fps)))
	append(
		&lines,
		fmt.tprintf(
			"{} {} {}",
			int(player.body.position.x),
			int(player.body.position.y),
			int(player.body.position.z),
		),
	)

	for action in DEBUG_ACTIONS {
		if action.state == nil {
			append(&lines, fmt.tprintf("{} {}", action.key_name, action.label))
			continue
		}
		append(
			&lines,
			fmt.tprintf("{} {} {}", action.key_name, action.label, action.state() ? "ON" : "OFF"),
		)
	}
	append(&lines, "^ HIDE   F12 HUD")

	widest: f32
	for text in lines {
		widest = max(widest, hud_text_width(text, size))
	}

	panel_width := widest + 2 * pad
	panel_height := line * f32(len(lines)) + 2 * pad - (line - size)
	x := right - panel_width

	hud_rect(x, top, panel_width, panel_height, HUD_PANEL, radius = 3 * scale)

	y := top + pad
	for text, i in lines {
		color := i == 0 ? HUD_WARN : HUD_DIM
		hud_text(x + pad, y, text, size, color)
		y += line
	}
}
