package main

import "core:math"

// Centre-screen messaging bands. Six call sites used to pick their own y and
// could overlap; now every message submits into one of three bands and the
// highest priority wins, with a shared enter/exit ease instead of hard pops.
//
// Submitters run first each frame; draw_banners resolves and draws last.

Banner_Band :: enum u8 {
	Top_Strip, // height * 0.20 -- one-line hints (MATCH POINT)
	Headline, // height * 0.28 -- phase headers and round results
	Action, // under the crosshair -- reload / plant / defuse
}

Banner :: struct {
	head:           string,
	sub:            string,
	note:           string,
	color:          [4]f32, // the head's colour; sub and note stay neutral
	priority:       int,
	progress:       f32, // Action band: > 0 draws the bar
	progress_color: [4]f32,
}

hud_banner: struct {
	slots:   [Banner_Band]Banner,
	filled:  [Banner_Band]bool,
	// retained per band: what is on screen and how far through its ease
	shown:   [Banner_Band]Banner,
	state_t: [Banner_Band]f32,
}

banner_submit :: proc(band: Banner_Band, b: Banner) {
	if hud_banner.filled[band] && hud_banner.slots[band].priority >= b.priority do return
	hud_banner.slots[band] = b
	hud_banner.filled[band] = true
}

// One winner per band, eased in over ~180ms and out over ~150ms. A new winner
// mid-display restarts the entrance so the change reads as an event.
draw_banners :: proc(width, height: f32) {
	scale := hud_scale()
	cx := width * 0.5

	for band in Banner_Band {
		target := hud_banner.filled[band]
		if target {
			if hud_banner.slots[band].head != hud_banner.shown[band].head {
				hud_banner.state_t[band] = 0
			}
			hud_banner.shown[band] = hud_banner.slots[band]
		}
		hud_banner.filled[band] = false

		hud_banner.state_t[band] = ui_approach(
			hud_banner.state_t[band],
			target ? 1 : 0,
			ui.dt,
			target ? 16 : 22,
		)
		t := hud_banner.state_t[band]
		if t < 0.02 do continue

		b := hud_banner.shown[band]
		e := ease_out_cubic(t)
		dy := (1 - e) * -12 * scale // slides down into place

		switch band {
		case .Top_Strip:
			size := hud_font_size(UI_LABEL * scale)
			hud_text_shadow(
				cx,
				height * 0.20 + dy,
				b.head,
				size,
				ui_fade(b.color, t),
				.Center,
				tracking = size * 0.16,
			)

		case .Headline:
			y := height * 0.28 + dy
			head_size := hud_font_size(44 * scale)
			hud_text_shadow(cx, y, b.head, head_size, ui_fade(b.color, t), .Center, tracking = head_size * 0.06)
			if b.sub != "" {
				hud_text_shadow(cx, y + 54 * scale, b.sub, UI_BODY * scale, ui_fade(HUD_WHITE, t), .Center)
			}
			if b.note != "" {
				note_size := hud_font_size(UI_LABEL * scale)
				hud_text(
					cx,
					y + 86 * scale,
					b.note,
					note_size,
					ui_fade(HUD_DIM, t),
					.Center,
					tracking = note_size * 0.10,
				)
			}

		case .Action:
			y := height * 0.5 + 46 * scale + dy * 0.5
			label_size := hud_font_size(UI_LABEL * scale)
			hud_text_shadow(
				cx,
				y,
				b.head,
				label_size,
				ui_fade(b.color, t),
				.Center,
				tracking = label_size * 0.12,
			)
			if b.progress > 0 {
				bar_w := 140 * scale
				bar_h := 3 * scale
				bar_y := math.round(y + label_size + 8 * scale)
				hud_rect(cx - bar_w * 0.5, bar_y, bar_w, bar_h, ui_fade(UI_STROKE, t * 0.8))
				hud_rect(
					cx - bar_w * 0.5,
					bar_y,
					bar_w * clamp(b.progress, 0, 1),
					bar_h,
					ui_fade(b.progress_color, t),
				)
			}
		}
	}
}
