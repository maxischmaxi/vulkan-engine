package main

import "core:fmt"
import "core:strings"
import "game"
import "protocol"

// The kill feed, top right: who took whom out and with what. Entries arrive
// through the reliable Kill broadcast every client already receives (the
// handler used to turn them into a sound and nothing else) and, offline,
// from the local sim's own kill detection.
//
// The per-pawn tally doubles as the scoreboard's K/D source until the roster
// message replicates authoritative numbers.

KILLFEED_VISIBLE :: 5
KILLFEED_SECONDS :: f32(6.0)

@(private = "file")
KILLFEED_IN :: f32(0.18)
@(private = "file")
KILLFEED_OUT :: f32(0.25)

Killfeed_Entry :: struct {
	used:                   bool,
	age:                    f32,
	killer, victim, weapon: u8,
	killer_ct, victim_ct:   bool,
	killer_bot, victim_bot: bool,
	world:                  bool, // killer 0xFF: fall damage and friends
	involves_local:         bool,
	local_practice:         bool, // offline: YOU -> TARGET
}

killfeed: struct {
	entries: [8]Killfeed_Entry, // newest first
	tally:   [game.MAX_PAWNS]struct {
		kills, deaths: int,
	},
}

@(private = "file")
killfeed_push :: proc(e: Killfeed_Entry) {
	for i := len(killfeed.entries) - 1; i > 0; i -= 1 {
		killfeed.entries[i] = killfeed.entries[i - 1]
	}
	killfeed.entries[0] = e
}

// The .Kill handler's other half: the sound stays there, the feed lands here.
killfeed_note_kill :: proc(m: protocol.Kill) {
	e := Killfeed_Entry {
		used   = true,
		killer = m.killer,
		victim = m.victim,
		weapon = m.weapon,
		world  = m.killer == 0xFF,
	}

	// Teams and botness read from the freshest snapshot now, while the pawn
	// is still in it; the entry outlives the pawn.
	snap := snapshot_at(net_client.latest_tick)
	if snap != nil {
		if !e.world && int(m.killer) < game.MAX_PAWNS && int(m.killer) in snap.present {
			ent := &snap.entities[m.killer]
			e.killer_ct = .Team_CT in ent.flags
			e.killer_bot = .Is_Bot in ent.flags
		}
		if int(m.victim) < game.MAX_PAWNS && int(m.victim) in snap.present {
			ent := &snap.entities[m.victim]
			e.victim_ct = .Team_CT in ent.flags
			e.victim_bot = .Is_Bot in ent.flags
		}
	}
	e.involves_local =
		int(m.killer) == net_client.pawn_id || int(m.victim) == net_client.pawn_id

	if !e.world && int(m.killer) < game.MAX_PAWNS do killfeed.tally[m.killer].kills += 1
	if int(m.victim) < game.MAX_PAWNS do killfeed.tally[m.victim].deaths += 1

	killfeed_push(e)
}

// The range has no Kill messages; the local sim reports its own.
killfeed_note_local :: proc(weapon: u8) {
	killfeed_push(
		{used = true, weapon = weapon, involves_local = true, local_practice = true},
	)
}

killfeed_reset :: proc() {
	killfeed = {}
}

@(private = "file")
killfeed_name :: proc(id: u8, bot, is_local: bool) -> string {
	if is_local {
		persona := steam_persona()
		return persona != "" ? persona : "YOU"
	}
	if int(id) < game.MAX_PAWNS {
		entry := &net_client.roster[id]
		if entry.known && entry.name_len > 0 {
			return string(entry.name[:entry.name_len])
		}
	}
	if bot do return fmt.tprintf("BOT %02d", id)
	return fmt.tprintf("PLAYER %02d", id)
}

draw_killfeed :: proc(right, top: f32) {
	scale := hud_scale()
	size := hud_font_size(UI_LABEL * scale)
	chip_size := hud_font_size(UI_MICRO * scale)
	row_h := size + 12 * scale
	gap := 5 * scale
	pad := 8 * scale

	shown := 0
	for &e in killfeed.entries {
		if !e.used do continue
		e.age += ui.dt
		if e.age > KILLFEED_SECONDS + KILLFEED_OUT {
			e.used = false
			continue
		}
		if shown >= KILLFEED_VISIBLE do continue

		// slide in from the right, fade out at end of life
		enter := ease_out_cubic(clamp(e.age / KILLFEED_IN, 0, 1))
		alpha := clamp((KILLFEED_SECONDS + KILLFEED_OUT - e.age) / KILLFEED_OUT, 0, 1)
		dx := (1 - enter) * 16 * scale

		killer_local := !e.world && int(e.killer) == net_client.pawn_id
		victim_local := int(e.victim) == net_client.pawn_id

		killer := ""
		victim := ""
		if e.local_practice {
			killer = killfeed_name(0, false, true)
			victim = "TARGET"
		} else {
			if !e.world do killer = killfeed_name(e.killer, e.killer_bot, killer_local)
			victim = killfeed_name(e.victim, e.victim_bot, victim_local)
		}
		weapon_name := ""
		if int(e.weapon) < game.WEAPON_COUNT {
			weapon_name = strings.to_upper(
				game.WEAPONS[e.weapon].name,
				context.temp_allocator,
			)
		}

		killer_w := killer == "" ? 0 : hud_text_width(killer, size)
		victim_w := hud_text_width(victim, size)
		chip_w := weapon_name == "" ? 0 : hud_text_width(weapon_name, chip_size) + 12 * scale
		total := killer_w + victim_w + chip_w + (killer == "" ? 1 : 2) * 10 * scale + 2 * pad

		x := right - total + dx
		y := top + f32(shown) * (row_h + gap)

		// the rows you are part of get a backing panel and the accent edge
		if e.involves_local {
			hud_rect(x, y, total, row_h, ui_fade(UI_PANEL, alpha))
			hud_rect(x, y, 2 * scale, row_h, ui_fade(UI_ACCENT, alpha))
		}

		pen := x + pad
		ty := y + (row_h - size) * 0.5
		if killer != "" {
			color := e.local_practice || killer_local ? HUD_WHITE : (e.killer_ct ? MENU_CT_COLOR : MENU_T_COLOR)
			pen = hud_text_shadow(pen, ty, killer, size, ui_fade(color, alpha))
			pen += 10 * scale
		}
		if weapon_name != "" {
			chip_h := chip_size + 6 * scale
			chip_y := y + (row_h - chip_h) * 0.5
			this_w := hud_text_width(weapon_name, chip_size) + 12 * scale
			hud_frame(pen, chip_y, this_w, chip_h, UI_STROKE_W * scale, ui_fade(UI_TEXT_FAINT, alpha))
			hud_text(
				pen + 6 * scale,
				chip_y + 3 * scale,
				weapon_name,
				chip_size,
				ui_fade(HUD_DIM, alpha),
			)
			pen += this_w + 10 * scale
		}
		victim_color := victim_local ? HUD_WHITE : (e.victim_ct ? MENU_CT_COLOR : MENU_T_COLOR)
		if e.local_practice do victim_color = HUD_DIM
		hud_text_shadow(pen, ty, victim, size, ui_fade(victim_color, alpha))

		shown += 1
	}
}

// The preview harness re-seeds fixed ages every frame so a screenshot shows
// entry, steady state and fade at once.
killfeed_preview_seed :: proc() {
	ages := [5]f32{0.06, 1, 2, 3, KILLFEED_SECONDS - 0.1}
	for age, i in ages {
		killfeed.entries[i] = {
			used           = true,
			age            = age,
			weapon         = u8(1 + i % 3),
			killer         = u8(2 + i),
			victim         = u8(8 + i),
			killer_ct      = i % 2 == 0,
			victim_ct      = i % 2 != 0,
			killer_bot     = i != 1,
			victim_bot     = true,
			world          = i == 4,
			involves_local = i == 1,
		}
	}
}
