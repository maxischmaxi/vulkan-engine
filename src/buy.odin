package main

import "core:fmt"
import "core:log"
import "core:strings"
import "game"
import "vendor:glfw"

// The buy menu, counter-strike style: B opens it anywhere in the match,
// categories on the number keys, items on the number keys below them, 0 backs
// out, the mouse works everywhere. Everything is free -- prices are shown
// because a buy menu without prices reads as a debug screen.
//
// The pending loadout is the client-side mirror of the slot the server keeps.
// Every buy goes over the reliable channel; during the countdown the same
// pure rule the server runs is applied locally, so both ends agree without an
// acknowledgement round-trip. Mid-round the choice waits for the respawn.

Buy_Page :: enum u8 {
	Categories,
	Pistols,
	Heavy,
	SMG,
	Rifles,
	Gear,
}

Buy_Menu :: struct {
	open:    bool,
	page:    Buy_Page,
	pending: game.Loadout,
}

buy_menu: Buy_Menu

BUY_MENU_KEY :: glfw.KEY_B
BUY_BACK_KEY :: glfw.KEY_0

// Category order is the classic buy menu's: 1 pistols, 2 heavy, 3 smg,
// 4 rifles, 5 gear.
@(private = "file")
BUY_CATEGORIES := [5]struct {
	label: string,
	page:  Buy_Page,
}{{"PISTOLS", .Pistols}, {"HEAVY", .Heavy}, {"SMG", .SMG}, {"RIFLES", .Rifles}, {"GEAR", .Gear}}

@(private = "file")
ITEM_KEYS := [9]i32 {
	glfw.KEY_1,
	glfw.KEY_2,
	glfw.KEY_3,
	glfw.KEY_4,
	glfw.KEY_5,
	glfw.KEY_6,
	glfw.KEY_7,
	glfw.KEY_8,
	glfw.KEY_9,
}

// One row of an item page: a weapon index, or -1 for the kevlar toggle.
@(private = "file")
Buy_Item :: struct {
	weapon: int,
}

// A fresh session: the seed is what the player owns until they buy.
buy_reset :: proc(l: game.Loadout) {
	buy_menu.open = false
	buy_menu.page = .Categories
	buy_menu.pending = l
}

// Whether the menu may be up at all: mid-game, on top of nothing else. Dead is
// fine -- buying for the next life is the point.
@(private = "file")
buy_allowed :: proc() -> bool {
	// On the range there is no phase to wait for: B works whenever the range
	// itself is up.
	if practice_active() {
		return !scene.paused && !settings_screen.open
	}
	return(
		scene_playing() &&
		!scene.paused &&
		!settings_screen.open &&
		!bench_active() &&
		net_client.joined &&
		buy_phase_open() \
	)
}

// Comp buys during warmup and freeze only; TDM additionally accepts a buy
// mid-match, delivered on respawn. Same split the server enforces.
@(private = "file")
buy_phase_open :: proc() -> bool {
	if game.phase_can_buy(net_client.phase) do return true
	return net_client.mode == .TDM && net_client.phase == .Live
}

@(private = "file")
open_buy_menu :: proc() {
	buy_menu.open = true
	buy_menu.page = .Categories
	grab_cursor(false)
}

@(private = "file")
close_buy_menu :: proc() {
	buy_menu.open = false
	if scene_playing() && !scene.paused && !settings_screen.open {
		grab_cursor(true)
	}
}

// The weapons a page offers this player, in table order. Team-restricted
// entries never show up -- the menu offers only what the server would accept.
@(private = "file")
buy_page_items :: proc(page: Buy_Page) -> (items: [9]Buy_Item, count: int) {
	if page == .Gear {
		items[0] = {
			weapon = -1,
		} 	// kevlar
		return items, 1
	}

	category: game.Buy_Category
	#partial switch page {
	case .Pistols:
		category = .Pistol
	case .Heavy:
		category = .Heavy
	case .SMG:
		category = .SMG
	case .Rifles:
		category = .Rifle
	case:
		return items, 0
	}

	for weapon, i in game.WEAPONS {
		if weapon.category != category do continue
		// The range came from the main menu without a team choice, so it
		// offers everything; a match offers only what the server would accept.
		if !practice_active() && scene.chosen_team not_in weapon.teams do continue
		if count >= len(items) do break
		items[count] = {
			weapon = i,
		}
		count += 1
	}
	return items, count
}

// What this row would cost right now: nothing for a rebuy or the armor
// toggle-off, the sticker price otherwise. Mirrors game.buy_cost so the
// client refuses exactly what the server would.
@(private = "file")
buy_item_cost :: proc(item: Buy_Item) -> int {
	if item.weapon < 0 {
		return buy_menu.pending.armor ? 0 : game.ECON_ARMOR_PRICE
	}
	if i8(item.weapon) == buy_menu.pending.primary ||
	   i8(item.weapon) == buy_menu.pending.secondary {
		return 0
	}
	return game.WEAPONS[item.weapon].price
}

// Money only binds in a comp freeze; warmup, TDM and the range stay free.
@(private = "file")
buy_money_enforced :: proc() -> bool {
	return competitive_active() && net_client.phase == .Freeze
}

@(private = "file")
buy_item_affordable :: proc(item: Buy_Item) -> bool {
	return !buy_money_enforced() || buy_item_cost(item) <= net_client.money
}

@(private = "file")
buy_item :: proc(item: Buy_Item) {
	if !buy_item_affordable(item) do return

	audio_emit({kind = .Buy, local = true})
	before := buy_menu.pending

	if item.weapon < 0 {
		buy_menu.pending.armor = !buy_menu.pending.armor
		log.infof("Buy: kevlar {}", buy_menu.pending.armor ? "on" : "off")
	} else {
		weapon := game.WEAPONS[item.weapon]
		if weapon.slot == 0 {
			buy_menu.pending.primary = i8(item.weapon)
		} else {
			buy_menu.pending.secondary = i8(item.weapon)
		}
		log.infof("Buy: {} ({})", weapon.name, weapon.price)
	}

	// Sent even from the range: the slot's loadout stays current for the day
	// matchmaking pulls someone out of practice. A no-op before the accept.
	net_send_loadout(buy_menu.pending)

	// The countdown delivery: the server applies the buy to the live pawn the
	// moment it arrives, so the local mirror does the same, with the same rule
	// deciding what ends up in the hands. The range delivers the same way --
	// immediately, no death required.
	if (practice_active() || game.phase_can_buy(net_client.phase)) && player.alive {
		held := weapon_state.index
		player.loadout = buy_menu.pending
		refill_all_ammo()
		select_weapon(game.loadout_held_after_buy(before, buy_menu.pending, held))
	}

	buy_menu.page = .Categories
}

// Called every frame right after the settings UI, before the tick loop.
update_buy_menu :: proc() {
	if !buy_allowed() {
		// The phase moved on or a modal took over; a stale open menu would
		// hold the cursor loose forever.
		if buy_menu.open do close_buy_menu()
		return
	}

	if key_pressed(BUY_MENU_KEY) {
		if buy_menu.open do close_buy_menu()
		else do open_buy_menu()
		return
	}
	if !buy_menu.open do return

	if key_pressed(glfw.KEY_ESCAPE) {
		close_buy_menu()
		return
	}

	if buy_menu.page == .Categories {
		for category, i in BUY_CATEGORIES {
			if key_pressed(ITEM_KEYS[i]) do buy_menu.page = category.page
		}
		return
	}

	if key_pressed(BUY_BACK_KEY) {
		buy_menu.page = .Categories
		return
	}
	items, count := buy_page_items(buy_menu.page)
	for i in 0 ..< count {
		if key_pressed(ITEM_KEYS[i]) do buy_item(items[i])
	}
}

// ------------------------------------------------------------------ drawing

// The open/close and page-change motion: eased in draw, reset when closed.
@(private = "file")
buy_open_t: f32
@(private = "file")
buy_prev_page: Buy_Page

// A menu row on the shared widget core: flat, an accent inset bar on hover,
// the good-coloured bar and an OWNED tag for what the pending loadout holds.
// No click sound here -- buy_item plays the purchase itself.
@(private = "file")
buy_row :: proc(
	x, y, w, h: f32,
	key_hint, label, price: string,
	equipped: bool,
	affordable := true,
	fade := f32(1),
	index := 0,
) -> bool {
	scale := hud_scale()
	hovered, t := ui_hot(ui_id(label, 200 + index), x, y, w, h, affordable)
	row_alpha := (affordable ? f32(1) : 0.35) * fade

	if t > 0.01 do hud_rect(x, y, w, h, ui_fade(UI_PANEL_RAISED, t * row_alpha))
	if equipped {
		hud_rect(x, y, 2 * scale, h, ui_fade(UI_GOOD, row_alpha))
	} else if t > 0.01 {
		bar_h := h * ease_out_cubic(t)
		hud_rect(x, y + (h - bar_h) * 0.5, 2 * scale, bar_h, ui_fade(UI_ACCENT, t * row_alpha))
	}

	size := hud_font_size(UI_LABEL * scale)
	hint_size := hud_font_size(UI_MICRO * scale)
	pad := 12 * scale
	text_y := y + (h - size) * 0.5
	color := hovered ? HUD_WHITE : HUD_DIM
	if !affordable do color = HUD_FAINT

	hud_text(
		x + pad,
		y + (h - hint_size) * 0.5,
		key_hint,
		hint_size,
		ui_fade(hovered ? HUD_WARN : HUD_FAINT, fade),
	)
	hud_text(
		x + pad + 34 * scale,
		text_y,
		strings.to_upper(label, context.temp_allocator),
		size,
		ui_fade(color, row_alpha),
		tracking = size * 0.08,
	)
	if equipped {
		hud_text(x + w - pad, text_y, "OWNED", size, ui_fade(HUD_GOOD, fade), .Right)
	} else {
		price_color := affordable ? (hovered ? HUD_WHITE : HUD_FAINT) : HUD_BAD
		hud_text(x + w - pad, text_y, price, size, ui_fade(price_color, row_alpha), .Right)
	}

	return hovered && consume_click()
}

@(private = "file")
buy_price_label :: proc(price: int) -> string {
	if price <= 0 do return "FREE"
	return fmt.tprintf("$%d", price)
}

draw_buy_menu :: proc(width, height: f32) {
	if !buy_menu.open {
		buy_open_t = 0
		return
	}

	// a fresh page replays a short slice of the entrance, so flipping between
	// categories and items reads as a change rather than a swap
	if buy_menu.page != buy_prev_page {
		buy_prev_page = buy_menu.page
		buy_open_t = min(buy_open_t, 0.55)
	}
	buy_open_t = ui_approach(buy_open_t, 1, ui.dt, 16)
	fade := buy_open_t
	slide := (1 - ease_out_cubic(buy_open_t)) * 14

	scale := hud_scale()
	size := hud_font_size(UI_LABEL * scale)
	row_h := size + 20 * scale
	gap := 4 * scale
	pad := 20 * scale

	panel_w := 520 * scale
	rows := buy_menu.page == .Categories ? len(BUY_CATEGORIES) : 9
	panel_h := f32(rows) * (row_h + gap) + row_h * 2.5 + 2 * pad

	x := (width - panel_w) * 0.5
	y := (height - panel_h) * 0.5 + slide * scale

	hud_rect(0, 0, width, height, ui_fade(UI_SCRIM_MED, fade))
	hud_rect(x, y, panel_w, panel_h, ui_fade(UI_PANEL, max(fade, 0.9)), radius = UI_RADIUS * scale)
	hud_frame(x, y, panel_w, panel_h, UI_STROKE_W * scale, ui_fade(UI_STROKE, fade))

	cursor := y + pad
	title := buy_menu.page == .Categories ? "BUY MENU" : buy_page_title(buy_menu.page)
	title_size := hud_font_size(UI_BODY * scale)
	title_end := hud_text(
		x + pad,
		cursor,
		title,
		title_size,
		ui_fade(HUD_WHITE, fade),
		tracking = title_size * 0.12,
	)
	if competitive_active() {
		money := net_client.phase == .Warmup ? "$INF" : fmt.tprintf("$%d", net_client.money)
		hud_text(title_end + 24 * scale, cursor, money, size, HUD_GOOD)
	}
	if practice_active() {
		// no team on the range; the pages offer both arsenals
		hud_text(x + panel_w - pad, cursor, "ALL", size, HUD_DIM, .Right)
	} else {
		team_label := scene.chosen_team == .T ? "T" : "CT"
		hud_text(
			x + panel_w - pad,
			cursor,
			team_label,
			size,
			scene.chosen_team == .T ? MENU_T_COLOR : MENU_CT_COLOR,
			.Right,
		)
	}
	cursor += row_h * 1.2

	if buy_menu.page == .Categories {
		for category, i in BUY_CATEGORIES {
			hint := fmt.tprintf("%d", i + 1)
			if buy_row(
				x + pad,
				cursor,
				panel_w - 2 * pad,
				row_h,
				hint,
				category.label,
				"",
				false,
				fade = fade,
				index = i,
			) {
				buy_menu.page = category.page
			}
			cursor += row_h + gap
		}
	} else {
		items, count := buy_page_items(buy_menu.page)
		for i in 0 ..< count {
			item := items[i]
			hint := fmt.tprintf("%d", i + 1)
			label: string
			price: string
			equipped: bool
			if item.weapon < 0 {
				label = "KEVLAR"
				price = buy_price_label(game.ECON_ARMOR_PRICE)
				equipped = buy_menu.pending.armor
			} else {
				weapon := game.WEAPONS[item.weapon]
				label = weapon.name
				price = buy_price_label(weapon.price)
				equipped =
					i8(item.weapon) == buy_menu.pending.primary ||
					i8(item.weapon) == buy_menu.pending.secondary
			}
			affordable := buy_item_affordable(item)
			if buy_row(
				x + pad,
				cursor,
				panel_w - 2 * pad,
				row_h,
				hint,
				label,
				price,
				equipped,
				affordable,
				fade = fade,
				index = 10 + i,
			) {
				buy_item(items[i])
			}
			cursor += row_h + gap
		}
	}

	// Footer: the controls, and where the goods go.
	footer_y := y + panel_h - pad - size
	hint := buy_menu.page == .Categories ? "B CLOSE" : "0 BACK   B CLOSE"
	hud_text(x + pad, footer_y, hint, size * 0.85, HUD_FAINT)
	if net_client.phase == .Live {
		hud_text(
			x + panel_w - pad,
			footer_y,
			"DELIVERED ON RESPAWN",
			size * 0.85,
			HUD_FAINT,
			.Right,
		)
	} else {
		hud_text(x + panel_w - pad, footer_y, "DELIVERED NOW", size * 0.85, HUD_GOOD, .Right)
	}

	// A click that hit no row dies here, like the scene screens do it.
	_ = consume_click()
}

@(private = "file")
buy_page_title :: proc(page: Buy_Page) -> string {
	#partial switch page {
	case .Pistols:
		return "PISTOLS"
	case .Heavy:
		return "HEAVY"
	case .SMG:
		return "SMG"
	case .Rifles:
		return "RIFLES"
	case .Gear:
		return "GEAR"
	}
	return ""
}
