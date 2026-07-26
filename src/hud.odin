package main

import "core:fmt"
import "core:math"
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

HUD_WHITE :: [4]f32{0.93, 0.95, 0.97, 1}
HUD_DIM :: [4]f32{0.66, 0.70, 0.74, 1}
HUD_FAINT :: [4]f32{0.42, 0.45, 0.50, 1}
HUD_GOOD :: [4]f32{0.45, 0.86, 0.50, 1}
HUD_WARN :: [4]f32{0.96, 0.74, 0.26, 1}
HUD_BAD :: [4]f32{0.93, 0.30, 0.28, 1}
HUD_PANEL :: [4]f32{0.03, 0.04, 0.05, 0.72}

// Below this the health readout starts pulsing, the way every shooter since
// Doom has warned that the next hit is the last one.
HUD_LOW_HEALTH :: 25

Hud :: struct {
	visible: bool,
}

hud := Hud {
	visible = true,
}

hud_scale :: proc() -> f32 {
	return max(0.5, f32(g.swapchain_extent.height) / HUD_REFERENCE_HEIGHT)
}

// Called from build_frame, once the simulation for this frame is settled.
build_hud :: proc() {
	// Not a debug tool: hiding the overlay for a screenshot is something a
	// shipped build should be able to do too.
	if key_pressed(glfw.KEY_F12) do hud.visible = !hud.visible

	update_minimap(clock.frame_dt)

	hud_begin_frame()
	defer hud_end_frame()

	// A minimised window has a zero extent, and every layout number below would
	// come out as zero or a division by it.
	if g.swapchain_extent.width == 0 || g.swapchain_extent.height == 0 do return
	if !hud.visible do return

	scale := hud_scale()
	width := f32(g.swapchain_extent.width)
	height := f32(g.swapchain_extent.height)
	margin := HUD_MARGIN * scale

	// Damage first, so everything else is legible on top of it.
	draw_damage_feedback(width, height)

	draw_minimap(margin, margin, HUD_MINIMAP_SIZE * scale)
	draw_status(width, margin)
	draw_health(margin, height - margin)
	draw_ammo(width - margin, height - margin)
	draw_slots(width * 0.5, height - margin)
	draw_weapon_prompt(width * 0.5, height * 0.5)

	if debug_active() do draw_debug_panel(width - margin, margin)
	if !player.alive do draw_death_overlay(width, height)
}

// ------------------------------------------------------------------- panels

// Top centre: how long this session has been running, and how it is going.
// The timer is where a round clock will go once rounds exist; until then it is
// simply the clock.
@(private = "file")
draw_status :: proc(width, margin: f32) {
	scale := hud_scale()
	center := width * 0.5

	elapsed := int(f32(clock.tick_count) * TICK_DT)
	timer := fmt.tprintf("{}:{:02d}", elapsed / 60, elapsed % 60)

	y := margin
	hud_text_shadow(center, y, timer, HUD_TEXT_MEDIUM * scale, HUD_WHITE, .Center)

	y += HUD_TEXT_MEDIUM * scale + 6 * scale
	hud_text_shadow(
		center,
		y,
		fmt.tprintf("{} KILLS   {} DEATHS", player.kills, player.deaths),
		HUD_TEXT_SMALL * scale,
		HUD_DIM,
		.Center,
	)

	y += HUD_TEXT_SMALL * scale + 4 * scale
	hud_text_shadow(
		center,
		y,
		fmt.tprintf("{} ENEMIES", bots_alive()),
		HUD_TEXT_SMALL * scale,
		HUD_FAINT,
		.Center,
	)
}

// Bottom left, counter-strike's corner for it: health over armour, each behind
// a shape rather than a word, because the number is what gets read.
@(private = "file")
draw_health :: proc(x, bottom: f32) {
	scale := hud_scale()
	icon := 18 * scale
	gap := 10 * scale

	health_y := bottom - HUD_TEXT_BIG * scale
	armor_y := health_y - HUD_TEXT_MEDIUM * scale - 8 * scale

	color := HUD_WHITE
	if player.health <= HUD_LOW_HEALTH {
		// Sine rather than a square blink: a hard flash at the moment you most
		// need to read the number is the wrong kind of urgent.
		pulse := 0.65 + 0.35 * math.sin(f32(clock.tick_count) * TICK_DT * 9)
		color = {HUD_BAD.r, HUD_BAD.g * pulse, HUD_BAD.b * pulse, 1}
	} else if player.health <= 50 {
		color = HUD_WARN
	}

	// A cross, drawn as two bars.
	cross_y := health_y + (HUD_TEXT_BIG * scale - icon) * 0.5
	bar := max(2, math.round(icon * 0.3))
	hud_rect(x + (icon - bar) * 0.5, cross_y, bar, icon, color)
	hud_rect(x, cross_y + (icon - bar) * 0.5, icon, bar, color)

	hud_text_shadow(
		x + icon + gap,
		health_y,
		fmt.tprintf("{}", max(player.health, 0)),
		HUD_TEXT_BIG * scale,
		color,
	)

	if player.armor <= 0 do return

	armor_icon := 14 * scale
	armor_center := armor_y + (HUD_TEXT_MEDIUM * scale - armor_icon) * 0.5
	hud_rect(
		x + (icon - armor_icon) * 0.5,
		armor_center,
		armor_icon,
		armor_icon,
		HUD_DIM,
		radius = armor_icon * 0.35,
	)
	hud_text_shadow(
		x + icon + gap,
		armor_y,
		fmt.tprintf("{}", player.armor),
		HUD_TEXT_MEDIUM * scale,
		HUD_DIM,
	)
}

// Bottom right: magazine over reserve, with the weapon named above them. A melee
// weapon has neither, so it says so instead of showing two zeroes.
@(private = "file")
draw_ammo :: proc(right, bottom: f32) {
	scale := hud_scale()
	weapon := current_weapon()

	name_y := bottom - HUD_TEXT_BIG * scale - HUD_TEXT_SMALL * scale - 8 * scale
	hud_text_shadow(right, name_y, weapon.name, HUD_TEXT_SMALL * scale, HUD_DIM, .Right)

	value_y := bottom - HUD_TEXT_BIG * scale

	if weapon.melee {
		hud_text_shadow(right, value_y, "MELEE", HUD_TEXT_BIG * scale, HUD_DIM, .Right)
		return
	}

	ammo := current_ammo()

	// The reserve is dimmer and smaller than the magazine: what matters in a
	// firefight is how many rounds are left before the reload, not after it.
	reserve := fmt.tprintf("/ {}", ammo.reserve)
	reserve_width := hud_text_width(reserve, HUD_TEXT_MEDIUM * scale)
	reserve_color := ammo.reserve <= 0 ? HUD_BAD : HUD_FAINT

	// Sits on the baseline of the magazine number rather than its top.
	hud_text_shadow(
		right,
		value_y + (HUD_TEXT_BIG - HUD_TEXT_MEDIUM) * scale,
		reserve,
		HUD_TEXT_MEDIUM * scale,
		reserve_color,
		.Right,
	)

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
		HUD_TEXT_BIG * scale,
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

	labels: [WEAPON_SLOTS]string
	widths: [WEAPON_SLOTS]f32
	total: f32

	for slot in 0 ..< WEAPON_SLOTS {
		index := weapon_in_slot(slot)
		labels[slot] =
			index >= 0 ? fmt.tprintf("{} {}", slot + 1, WEAPONS[index].name) : fmt.tprintf("{}", slot + 1)
		widths[slot] = hud_text_width(labels[slot], size) + 2 * pad
		total += widths[slot]
	}
	total += gap * f32(WEAPON_SLOTS - 1)

	x := center - total * 0.5
	y := bottom - height

	for slot in 0 ..< WEAPON_SLOTS {
		index := weapon_in_slot(slot)
		active := index == weapon_state.index

		background := active ? [4]f32{0.85, 0.88, 0.92, 0.90} : HUD_PANEL
		text_color := HUD_FAINT
		if active {
			text_color = {0.06, 0.07, 0.08, 1}
		} else if index >= 0 {
			text_color = HUD_DIM
		}

		hud_rect(x, y, widths[slot], height, background, radius = 3 * scale)
		hud_text(x + widths[slot] * 0.5, y + pad, labels[slot], size, text_color, .Center)

		x += widths[slot] + gap
	}
}

// Just under the crosshair, where the eye already is: what the weapon is doing
// when it is not shooting.
@(private = "file")
draw_weapon_prompt :: proc(center_x, center_y: f32) {
	scale := hud_scale()
	weapon := current_weapon()
	y := center_y + 46 * scale

	progress := reload_progress()
	if progress > 0 {
		width := 120 * scale
		height := 6 * scale

		hud_text_shadow(center_x, y, "RELOADING", HUD_TEXT_SMALL * scale, HUD_WHITE, .Center)

		bar_y := y + HUD_TEXT_SMALL * scale + 6 * scale
		hud_rect(center_x - width * 0.5, bar_y, width, height, HUD_PANEL, radius = height * 0.5)
		hud_rect(
			center_x - width * 0.5,
			bar_y,
			width * progress,
			height,
			HUD_WHITE,
			radius = height * 0.5,
		)
		return
	}

	if weapon.melee do return

	ammo := current_ammo()
	if ammo.mag > 0 do return

	prompt := ammo.reserve > 0 ? "PRESS R TO RELOAD" : "OUT OF AMMO"
	hud_text_shadow(center_x, y, prompt, HUD_TEXT_SMALL * scale, HUD_BAD, .Center)
}

// Red at the edges plus a wedge pointing at whoever fired. The wedge is the part
// that matters: without sound, the direction of the shot is information the
// player has no other way to get.
@(private = "file")
draw_damage_feedback :: proc(width, height: f32) {
	if player.damage_flash <= 0 do return

	scale := hud_scale()
	strength := player.damage_flash / DAMAGE_FLASH_TIME

	band := 90 * scale
	edge := [4]f32{0.75, 0.05, 0.05, strength * 0.45}
	hud_rect(0, 0, width, band, edge)
	hud_rect(0, height - band, width, band, edge)
	hud_rect(0, band, band, height - 2 * band, edge)
	hud_rect(width - band, band, band, height - 2 * band, edge)

	if player.damage_dir == {} do return

	// Relative to where the player is looking, not to the world: the indicator
	// has to move when the view turns.
	relative := math.atan2(player.damage_dir.y, player.damage_dir.x) - math.to_radians(camera.yaw)

	// Straight ahead is up the screen, and the screen's y axis points down.
	heading := [2]f32{-math.sin(relative), -math.cos(relative)}
	center := [2]f32{width * 0.5, height * 0.5}
	position := center + heading * 130 * scale

	hud_rect_rotated(
		position.x,
		position.y,
		46 * scale,
		9 * scale,
		-relative,
		{0.95, 0.22, 0.20, strength},
	)
}

@(private = "file")
draw_death_overlay :: proc(width, height: f32) {
	scale := hud_scale()

	hud_rect(0, 0, width, height, {0.02, 0.02, 0.03, 0.55})

	center_x := width * 0.5
	y := height * 0.5 - HUD_TEXT_BIG * scale

	hud_text_shadow(center_x, y, "ELIMINATED", HUD_TEXT_BIG * scale, HUD_BAD, .Center)

	// Ceiling, so the last visible number is 1 rather than 0.
	remaining := int(math.ceil(max(player.respawn_in, 0)))
	hud_text_shadow(
		center_x,
		y + HUD_TEXT_BIG * scale + 12 * scale,
		fmt.tprintf("RESPAWNING IN {}", remaining),
		HUD_TEXT_MEDIUM * scale,
		HUD_DIM,
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
