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
	blink_phase: f32,
}

draw_topbar :: proc(width, margin: f32) {
	scale := hud_scale()
	cx := width * 0.5
	top := margin

	timer_w := 96 * scale
	score_w := 52 * scale
	bar_h := 44 * scale
	pip_w := 12 * scale
	pip_h := 24 * scale
	pip_gap := 5 * scale

	// one dark slab behind score-timer-score
	slab_w := timer_w + 2 * score_w
	hud_rect(cx - slab_w * 0.5, top, slab_w, bar_h, HUD_PANEL, radius = 4 * scale)

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
		size := hud_font_size(HUD_TEXT_MEDIUM * scale)
		hud_text_shadow(
			cx,
			top + (bar_h - size) * 0.5,
			fmt.tprintf("{}:{:02d}", seconds / 60, seconds % 60),
			size,
			color,
			.Center,
		)
	}

	// scores, each on its team color; underline marks the own side
	score_size := hud_font_size(HUD_TEXT_MEDIUM * scale)
	score_y := top + (bar_h - score_size) * 0.5
	t_x := cx - timer_w * 0.5 - score_w * 0.5
	ct_x := cx + timer_w * 0.5 + score_w * 0.5
	hud_text_shadow(t_x, score_y, fmt.tprintf("{}", net_client.t_score), score_size, MENU_T_COLOR, .Center)
	hud_text_shadow(ct_x, score_y, fmt.tprintf("{}", net_client.ct_score), score_size, MENU_CT_COLOR, .Center)
	underline_x := scene.chosen_team == .T ? t_x : ct_x
	hud_rect(underline_x - 10 * scale, top + bar_h - 4 * scale, 20 * scale, 2 * scale, HUD_DIM)

	// alive pips, five a side, growing outward; the dead stay as hollow frames
	t_alive, ct_alive := topbar_alive_counts()
	pip_y := top + (bar_h - pip_h) * 0.5
	for i in 0 ..< 5 {
		x_t := cx - slab_w * 0.5 - 10 * scale - f32(i + 1) * (pip_w + pip_gap)
		x_ct := cx + slab_w * 0.5 + 10 * scale + f32(i) * (pip_w + pip_gap)
		if i < t_alive {
			hud_rect(x_t, pip_y, pip_w, pip_h, MENU_T_COLOR, radius = 2 * scale)
		} else {
			hud_frame(x_t, pip_y, pip_w, pip_h, max(1, 1 * scale), HUD_FAINT)
		}
		if i < ct_alive {
			hud_rect(x_ct, pip_y, pip_w, pip_h, MENU_CT_COLOR, radius = 2 * scale)
		} else {
			hud_frame(x_ct, pip_y, pip_w, pip_h, max(1, 1 * scale), HUD_FAINT)
		}
	}

	// the personal line draw_status used to carry
	hud_text_shadow(
		cx,
		top + bar_h + 8 * scale,
		fmt.tprintf("{} KILLS   {} DEATHS", player.kills, player.deaths),
		HUD_TEXT_SMALL * scale,
		HUD_DIM,
		.Center,
	)
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
