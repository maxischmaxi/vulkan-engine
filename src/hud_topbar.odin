package main

import "core:fmt"
import "core:math"
import "game"

// The competitive top bar, CS-style at top center: score beside the round
// clock, five alive pips per team growing outward, the player's K/D under it.
// Replaces draw_status entirely while a comp match runs. Alive counts come
// from the newest snapshot's present mask -- remote.drawn would miss the
// local player and everyone mid-death.

hud_topbar: struct {
	// Accumulated blink phase for the planted bomb: integrated per frame so
	// the accelerating frequency never skips a beat.
	blink_phase:      f32,
	// A pip that just died flashes accent before it fades to a stub.
	prev_t, prev_ct:  int,
	flash_t, flash_ct: f32,
}

draw_topbar :: proc(width, margin: f32) {
	scale := hud_scale()
	cx := width * 0.5
	top := margin

	timer_w := 96 * scale
	score_w := 56 * scale
	bar_h := 44 * scale
	pip_w := 4 * scale
	pip_h := 20 * scale
	pip_gap := 6 * scale

	// one flat slab behind score-timer-score, hairline base, sharp corners;
	// the scores sit on team-tinted thirds
	slab_w := timer_w + 2 * score_w
	slab_x := cx - slab_w * 0.5
	hud_rect(slab_x, top, slab_w, bar_h, UI_PANEL)
	t_bg := ui_mix(UI_PANEL, UI_T_COLOR, 0.18)
	t_bg.a = UI_PANEL.a
	ct_bg := ui_mix(UI_PANEL, UI_CT_COLOR, 0.18)
	ct_bg.a = UI_PANEL.a
	hud_rect(slab_x, top, score_w, bar_h, t_bg)
	hud_rect(slab_x + slab_w - score_w, top, score_w, bar_h, ct_bg)
	hud_rect(slab_x, top + bar_h - 1 * scale, slab_w, 1 * scale, UI_STROKE)

	// the middle: round clock, or the blinking bomb once it is planted
	if net_client.phase == .Bomb {
		remaining := max(net_client.time_left, 0)
		// 1 Hz with a full fuse, ~6 Hz at zero
		hud_topbar.blink_phase += game.clock.frame_dt * (1.0 + 5.0 * (1.0 - remaining / 40.0))
		if math.mod(hud_topbar.blink_phase, 1.0) < 0.5 {
			s := 16 * scale
			hud_rect(cx - s * 0.5, top + (bar_h - s) * 0.5, s, s, HUD_BAD, radius = 3 * scale)
		}
	} else {
		seconds := max(int(math.ceil(net_client.time_left)), 0)
		color := HUD_WHITE
		if net_client.phase == .Live && seconds <= 10 do color = HUD_BAD
		size := hud_font_size(28 * scale)
		hud_text_shadow(
			cx,
			top + (bar_h - size) * 0.5,
			fmt.tprintf("{}:{:02d}", seconds / 60, seconds % 60),
			size,
			color,
			.Center,
		)
	}

	// scores, each on its team color; the accent underline marks the own side
	score_size := hud_font_size(26 * scale)
	score_y := top + (bar_h - score_size) * 0.5
	t_x := cx - timer_w * 0.5 - score_w * 0.5
	ct_x := cx + timer_w * 0.5 + score_w * 0.5
	hud_text_shadow(t_x, score_y, fmt.tprintf("{}", net_client.t_score), score_size, MENU_T_COLOR, .Center)
	hud_text_shadow(ct_x, score_y, fmt.tprintf("{}", net_client.ct_score), score_size, MENU_CT_COLOR, .Center)
	underline_x := scene.chosen_team == .T ? t_x : ct_x
	hud_rect(underline_x - 12 * scale, top + bar_h - 2 * scale, 24 * scale, 2 * scale, UI_ACCENT)

	// alive pips, thin bars five a side growing outward; the dead fade to
	// faint stubs rather than hollow frames -- less chrome, same read
	t_alive, ct_alive := topbar_alive_counts()
	if t_alive < hud_topbar.prev_t do hud_topbar.flash_t = 0.25
	if ct_alive < hud_topbar.prev_ct do hud_topbar.flash_ct = 0.25
	hud_topbar.prev_t, hud_topbar.prev_ct = t_alive, ct_alive
	hud_topbar.flash_t = max(hud_topbar.flash_t - ui.dt, 0)
	hud_topbar.flash_ct = max(hud_topbar.flash_ct - ui.dt, 0)

	pip_y := top + (bar_h - pip_h) * 0.5
	for i in 0 ..< 5 {
		x_t := slab_x - 12 * scale - f32(i + 1) * (pip_w + pip_gap)
		x_ct := slab_x + slab_w + 12 * scale + f32(i) * (pip_w + pip_gap)
		t_color := i < t_alive ? MENU_T_COLOR : ui_fade(UI_TEXT_FAINT, 0.35)
		ct_color := i < ct_alive ? MENU_CT_COLOR : ui_fade(UI_TEXT_FAINT, 0.35)
		// the freshest dead pip flashes accent for a beat
		if i == t_alive && hud_topbar.flash_t > 0 {
			t_color = ui_fade(UI_ACCENT, hud_topbar.flash_t / 0.25)
		}
		if i == ct_alive && hud_topbar.flash_ct > 0 {
			ct_color = ui_fade(UI_ACCENT, hud_topbar.flash_ct / 0.25)
		}
		hud_rect(x_t, pip_y, pip_w, pip_h, t_color)
		hud_rect(x_ct, pip_y, pip_w, pip_h, ct_color)
	}
	// the K/D line moved to the scoreboard; the bar stays scores-and-state
}

@(private = "file")
topbar_alive_counts :: proc() -> (t, ct: int) {
	if hud_preview_active() {
		return HUD_PREVIEW_T_ALIVE, HUD_PREVIEW_CT_ALIVE
	}
	snap := snapshot_at(net_client.latest_tick)
	if snap == nil do return
	for i in 0 ..< game.MAX_PAWNS {
		if i not_in snap.present do continue
		e := &snap.entities[i]
		if .Alive not_in e.flags do continue
		if .Team_CT in e.flags {
			ct += 1
		} else {
			t += 1
		}
	}
	return min(t, 5), min(ct, 5)
}
