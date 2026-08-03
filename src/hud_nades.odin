package main

import "core:fmt"
import "game"
import "vendor:glfw"

// The belt, bottom right above the ammo: one row per kind carried, the count
// beside it, and the row in hand lit up.
//
// Only what is actually carried appears. A fixed five-row rack would be steadier
// to look at, but it would also spend most of a round showing four things you
// do not have, and the one number that matters ("do I still have a smoke?")
// would be a shape to read rather than a row to count.
//
// Everything here is the client mirroring the server: player.grenades comes
// straight out of the private block (predict.odin), so a row disappears when the
// server says the grenade left the hand, not when the client thinks it threw.

HUD_NADE_ROW :: f32(30) // outer height of one row, reference pixels
HUD_NADE_GAP :: f32(4)
HUD_NADE_CHIP :: f32(22) // the coloured square's side
// Wide enough for the longest label and the count beside it without the two
// touching. "FLASH" at UI_MICRO with tracking is what sets it.
HUD_NADE_WIDTH :: f32(124)

// Short names, because the row is 96 reference pixels wide and "MOLOTOV" is
// not. The same four the killfeed and the buy menu spell out in full.
HUD_NADE_LABELS := [game.Grenade_Kind]string {
	.He      = "HE",
	.Flash   = "FLASH",
	.Smoke   = "SMOKE",
	.Molotov = "FIRE",
}

hud_nades: struct {
	// The selection highlight slides between rows instead of jumping, the way
	// the weapon strip's underline does.
	marker_y: f32,
	seeded:   bool,
}

// One entry of the drawn list: what the row says and whether it is in hand.
@(private = "file")
Nade_Row :: struct {
	label:  string,
	count:  int,
	color:  [4]f32,
	active: bool,
}

// Bottom right, growing upward from the top of the ammo block. Returns nothing:
// the ammo block's height is a shared constant, so the two cannot drift into
// each other the way the health and money blocks once did.
draw_nade_belt :: proc(right, bottom: f32) {
	scale := hud_scale()
	hand := hand_current()

	rows: [game.MAX_CARRY]Nade_Row
	count := 0
	for kind in game.Grenade_Kind {
		held := int(player.grenades[kind])
		if held <= 0 do continue

		c := PROJECTILE_COLORS[kind]
		rows[count] = {
			label  = HUD_NADE_LABELS[kind],
			count  = held,
			color  = {c.r, c.g, c.b, 1},
			active = hand.kind == .Grenade && hand.index == i8(kind),
		}
		count += 1
	}
	if local_carries_bomb() {
		rows[count] = {
			label  = "C4",
			count  = 1,
			color  = UI_ACCENT,
			active = hand.kind == .Bomb,
		}
		count += 1
	}
	if count == 0 {
		hud_nades.seeded = false
		return
	}

	row_h := HUD_NADE_ROW * scale
	gap := HUD_NADE_GAP * scale
	width := HUD_NADE_WIDTH * scale
	x := right - width
	// Bottom row sits directly above the ammo block; the list grows upward.
	top := bottom - f32(count) * row_h - f32(count - 1) * gap

	target_y := top
	for i in 0 ..< count {
		y := top + f32(i) * (row_h + gap)
		if rows[i].active do target_y = y
		draw_nade_row(x, y, width, row_h, rows[i])
	}

	// The marker: an accent bar down the left edge of the row in hand. It eases
	// between rows, so a scroll through the belt reads as one movement rather
	// than as four separate frames.
	if !hud_nades.seeded {
		hud_nades.marker_y = target_y
		hud_nades.seeded = true
	}
	hud_nades.marker_y = ui_approach(hud_nades.marker_y, target_y, ui.dt, 22)

	has_active := false
	for i in 0 ..< count do if rows[i].active do has_active = true
	if has_active {
		hud_rect(x - 5 * scale, hud_nades.marker_y, 2 * scale, row_h, UI_ACCENT)
	}
}

@(private = "file")
draw_nade_row :: proc(x, y, w, h: f32, row: Nade_Row) {
	scale := hud_scale()
	chip := HUD_NADE_CHIP * scale
	pad := (h - chip) * 0.5

	// The row itself: dark plate, brighter and outlined while it is in hand.
	plate := row.active ? UI_PANEL_RAISED : ui_fade(UI_PANEL, 0.55)
	hud_rect(x, y, w, h, plate, radius = UI_RADIUS * scale)
	if row.active {
		hud_frame(x, y, w, h, UI_STROKE_W * scale, ui_fade(UI_STROKE, 0.9))
	}

	// The colour square, the same colour the thing has in the air
	// (PROJECTILE_COLORS) so what you picked and what you see flying match.
	swatch := row.active ? row.color : ui_fade(row.color, 0.55)
	hud_rect(x + pad, y + pad, chip, chip, swatch, radius = UI_RADIUS * scale)

	// Shadowed like the rest of the HUD: these sit over the sky as often as
	// over the ground, and dim grey on pale blue is unreadable.
	label_size := hud_font_size(UI_MICRO * scale)
	label_color := row.active ? UI_TEXT : UI_TEXT_DIM
	hud_text_shadow(
		x + pad + chip + 8 * scale,
		y + (h - label_size) * 0.5,
		row.label,
		label_size,
		label_color,
		tracking = label_size * 0.1,
	)

	// The count is only worth a number when there is more than one; a lone
	// grenade says so by being on the list at all.
	if row.count > 1 {
		size := hud_font_size(UI_LABEL * scale)
		hud_text_shadow(
			x + w - 8 * scale,
			y + (h - size) * 0.5,
			fmt.tprintf("x{}", row.count),
			size,
			label_color,
			.Right,
		)
	}
}

// Under the crosshair, while the carrier stands on a site holding Use with the
// bomb still in the backpack. Without it the new plant rule reads as a broken
// plant rather than as a rule.
draw_plant_hint :: proc() {
	if !local_carries_bomb() do return
	if hand_view.bomb do return
	if net_client.phase != .Live do return
	if !key_down(glfw.KEY_E) do return // the plant/defuse key, as in build_local_input
	if game.bomb_site_at(game.MAP_BOMBSITES, player.body.position) < 0 do return

	banner_submit(.Action, {head = "PRESS 5 FOR THE BOMB", color = HUD_WARN, priority = 60})
}
