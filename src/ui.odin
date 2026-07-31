package main

import "core:fmt"
import "core:hash"
import "vendor:glfw"

// The widget vocabulary every screen builds from. Immediate mode with one
// retained detail: hover eases 0..1 per widget, keyed by ui_id in ui.anims.
// Click discipline is inherited from the menus -- consume_click is only taken
// while the cursor is inside the widget, and every screen still ends with a
// bare `_ = consume_click()` so a missed click dies there.
//
// The look: flat panels, hairline strokes, and an accent line that grows in
// on hover. No fills that shout; the accent is the statement.

Ui_Variant :: enum u8 {
	Primary, // the screen's one call to action; accent-stroked
	Secondary, // the default
	Danger, // quit, leave, discard
	Ghost, // text only, for nav rails and BACK
	Ghost_Danger, // a rail item that destroys something
}

Ui_Anim :: struct {
	hover:      f32, // eased 0..1
	hovered:    bool, // last frame's raw state, for the hover-edge sound
	last_frame: u64,
}

// Implicit widget identity: the label, disambiguated by id_extra when the
// same label appears twice on one screen (list rows).
ui_id :: proc(label: string, extra := 0) -> u64 {
	return hash.fnv64a(transmute([]u8)label) ~ u64(extra) * 0x9E3779B97F4A7C15
}

// Whether the loose cursor is inside the rect. Grabbed cursor and an active
// scene transition both mean "nothing is hoverable".
cursor_in :: proc(x, y, w, h: f32) -> bool {
	if input.cursor_grabbed || ui_transition_active() do return false
	return(
		input.cursor_x >= x &&
		input.cursor_x < x + w &&
		input.cursor_y >= y &&
		input.cursor_y < y + h \
	)
}

// The retained half of every widget: eases hover, plays the hover tick on the
// rising edge, and resets to rest when the widget was absent last frame (a
// screen change), so screens always animate in from zero.
ui_hot :: proc(id: u64, x, y, w, h: f32, enabled := true) -> (hovered: bool, t: f32) {
	hovered = enabled && cursor_in(x, y, w, h)
	return hovered, ui_hot_manual(id, hovered)
}

// The same, with the hit test handed in: for widgets that are not axis-aligned
// rectangles, like the halves of the diagonal split select.
ui_hot_manual :: proc(id: u64, hovered: bool) -> (t: f32) {
	anim := ui.anims[id]
	if anim.last_frame + 1 < ui.frame do anim = {}
	anim.last_frame = ui.frame

	if hovered && !anim.hovered do audio_emit({kind = .Ui_Hover, local = true})
	anim.hovered = hovered
	anim.hover = ui_approach(anim.hover, hovered ? 1 : 0, ui.dt, 18)
	ui.anims[id] = anim
	return anim.hover
}

ui_clicked :: proc(hovered: bool) -> bool {
	clicked := hovered && consume_click()
	if clicked do audio_emit({kind = .Ui_Click, local = true})
	return clicked
}

// True while any slider owns the mouse; the settings screen defers saving
// until the drag ends.
ui_drag_active :: proc() -> bool {
	return ui.active_id != 0
}

ui_mix :: proc(a, b: [4]f32, t: f32) -> [4]f32 {
	return a + (b - a) * t
}

ui_fade :: proc(color: [4]f32, alpha: f32) -> [4]f32 {
	c := color
	c.a *= alpha
	return c
}

// ------------------------------------------------------------------- widgets

ui_panel :: proc(x, y, w, h: f32, accent := false) {
	scale := hud_scale()
	hud_rect(x, y, w, h, UI_PANEL, radius = UI_RADIUS * scale)
	hud_frame(x, y, w, h, UI_STROKE_W * scale, UI_STROKE)
	if accent do hud_rect(x, y, 2 * scale, h, UI_ACCENT)
}

// Letter-spaced uppercase heading; the tracking is what makes small labels
// read as designed rather than typed.
ui_heading :: proc(
	x, y: f32,
	text: string,
	size: f32,
	color := UI_TEXT,
	align := Hud_Align.Left,
	track := f32(0.12),
) -> f32 {
	return hud_text(x, y, text, size, color, align, tracking = size * track)
}

ui_button :: proc(
	x, y, w, h: f32,
	label: string,
	variant := Ui_Variant.Secondary,
	enabled := true,
	focused := false,
	fade := f32(1), // entrance animations multiply in through here
	id_extra := 0,
) -> bool {
	scale := hud_scale()
	hovered, t := ui_hot(ui_id(label, id_extra), x, y, w, h, enabled)
	t = max(t, focused ? 1 : 0)
	alpha := (enabled ? f32(1) : 0.35) * fade

	accent := UI_TEXT
	#partial switch variant {
	case .Primary, .Danger, .Ghost_Danger:
		accent = UI_ACCENT
	}

	if variant == .Ghost || variant == .Ghost_Danger {
		// text-first: no chassis, an accent bar and a slide instead
		bar_h := h * ease_out_cubic(t)
		if bar_h > 1 {
			hud_rect(x, y + (h - bar_h) * 0.5, 2 * scale, bar_h, ui_fade(accent, alpha))
		}
		size := hud_font_size(UI_BODY * scale)
		color := ui_mix(UI_TEXT_DIM, variant == .Ghost_Danger ? UI_ACCENT : UI_TEXT, t)
		hud_text(
			x + (12 + 8 * ease_out_cubic(t)) * scale,
			y + (h - size) * 0.5,
			label,
			size,
			ui_fade(color, alpha),
			tracking = size * 0.08,
		)
		return ui_clicked(hovered)
	}

	hud_rect(x, y, w, h, ui_fade(ui_mix(UI_PANEL, UI_PANEL_RAISED, t), alpha), radius = UI_RADIUS * scale)
	stroke := ui_mix(UI_STROKE, accent, variant == .Primary ? max(t, 0.45) : t)
	hud_frame(x, y, w, h, UI_STROKE_W * scale, ui_fade(stroke, alpha))

	// the hover signature: an accent line growing from the bottom centre
	uw := (w - 8 * scale) * ease_out_cubic(t)
	if uw > 1 {
		hud_rect(x + (w - uw) * 0.5, y + h - 2 * scale, uw, 2 * scale, ui_fade(accent, alpha))
	}

	size := hud_font_size(UI_BODY * scale)
	color := ui_mix(UI_TEXT_DIM, variant == .Danger ? UI_ACCENT : UI_TEXT, t)
	hud_text(
		x + w * 0.5,
		y + (h - size) * 0.5,
		label,
		size,
		ui_fade(color, alpha),
		.Center,
		tracking = size * 0.08,
	)
	return ui_clicked(hovered)
}

// A labelled on/off row. Returns true on change.
ui_toggle :: proc(x, y, w, h: f32, label: string, value: ^bool, focused := false, id_extra := 0) -> bool {
	scale := hud_scale()
	hovered, t := ui_hot(ui_id(label, id_extra), x, y, w, h)
	t = max(t, focused ? 1 : 0)

	if t > 0.01 do hud_rect(x, y, w, h, ui_fade(UI_PANEL_RAISED, t))
	if focused do hud_rect(x, y, 2 * scale, h, UI_ACCENT)

	size := hud_font_size(UI_LABEL * scale)
	ty := y + (h - size) * 0.5
	hud_text(x + UI_PAD * scale, ty, label, size, ui_mix(UI_TEXT_DIM, UI_TEXT, t), tracking = size * 0.10)

	// the state block: a small square, filled when on
	box := size * 0.9
	bx := x + w - UI_PAD * scale - box
	by := y + (h - box) * 0.5
	if value^ {
		hud_rect(bx, by, box, box, UI_ACCENT)
	} else {
		hud_frame(bx, by, box, box, UI_STROKE_W * scale, UI_STROKE)
	}
	hud_text(bx - 8 * scale, ty, value^ ? "ON" : "OFF", size, value^ ? UI_TEXT : UI_TEXT_FAINT, .Right)

	changed := ui_clicked(hovered)
	if focused && (key_pressed(glfw.KEY_LEFT) || key_pressed(glfw.KEY_RIGHT)) do changed = true
	if changed do value^ = !value^
	return changed
}

// A labelled value with arrows either side. Returns -1/+1 when stepped, by
// click on an arrow zone or LEFT/RIGHT while focused; the caller applies it.
ui_cycler :: proc(x, y, w, h: f32, label, value: string, focused := false, id_extra := 0) -> int {
	scale := hud_scale()
	hovered, t := ui_hot(ui_id(label, id_extra), x, y, w, h)
	t = max(t, focused ? 1 : 0)

	if t > 0.01 do hud_rect(x, y, w, h, ui_fade(UI_PANEL_RAISED, t))
	if focused do hud_rect(x, y, 2 * scale, h, UI_ACCENT)

	size := hud_font_size(UI_LABEL * scale)
	ty := y + (h - size) * 0.5
	hud_text(x + UI_PAD * scale, ty, label, size, ui_mix(UI_TEXT_DIM, UI_TEXT, t), tracking = size * 0.10)

	// value right-aligned between the two arrow zones
	zone := h // square click targets
	arrow_color := t > 0.01 ? UI_TEXT_DIM : UI_TEXT_FAINT
	right_x := x + w - zone
	left_x := right_x - zone - hud_text_width(value, size) - 16 * scale

	hud_text(left_x + zone * 0.5, ty, "<", size, arrow_color, .Center)
	hud_text(right_x + zone * 0.5, ty, ">", size, arrow_color, .Center)
	hud_text(right_x - 8 * scale, ty, value, size, ui_mix(UI_TEXT_DIM, UI_TEXT, t), .Right)

	delta := 0
	if hovered && consume_click() {
		// left half of the row steps down only in the arrow zone; anywhere
		// else steps up, so clicking the row does the common thing
		delta = input.cursor_x < left_x + zone ? -1 : 1
		audio_emit({kind = .Ui_Click, local = true})
	}
	if focused {
		if key_pressed(glfw.KEY_LEFT) do delta = -1
		if key_pressed(glfw.KEY_RIGHT) do delta = 1
	}
	return delta
}

// A labelled draggable slider. Applies to value^ live and returns true on any
// change; the caller decides when to persist (see ui_drag_active).
ui_slider :: proc(
	x, y, w, h: f32,
	label: string,
	value: ^f32,
	lo, hi: f32,
	fmt_str := "%.2f",
	snap := f32(0),
	focused := false,
	id_extra := 0,
) -> bool {
	scale := hud_scale()
	id := ui_id(label, id_extra)
	hovered, t := ui_hot(id, x, y, w, h)
	t = max(t, focused ? 1 : 0)

	if t > 0.01 do hud_rect(x, y, w, h, ui_fade(UI_PANEL_RAISED, t))
	if focused do hud_rect(x, y, 2 * scale, h, UI_ACCENT)

	size := hud_font_size(UI_LABEL * scale)
	ty := y + (h - size) * 0.5
	hud_text(x + UI_PAD * scale, ty, label, size, ui_mix(UI_TEXT_DIM, UI_TEXT, t), tracking = size * 0.10)

	// track on the right half, value text at the far right
	value_w := 72 * scale
	track_w := w * 0.42
	track_x := x + w - UI_PAD * scale - value_w - track_w
	track_y := y + h * 0.5

	old := value^

	if hovered && consume_click() do ui.active_id = id
	if ui.active_id == id {
		frac := clamp((input.cursor_x - track_x) / track_w, 0, 1)
		value^ = lo + frac * (hi - lo)
	}
	if focused {
		step := snap > 0 ? snap : (hi - lo) / 20
		if key_pressed(glfw.KEY_LEFT) do value^ -= step
		if key_pressed(glfw.KEY_RIGHT) do value^ += step
	}
	if snap > 0 do value^ = math_round_to(value^, snap)
	value^ = clamp(value^, lo, hi)

	fill := (value^ - lo) / (hi - lo)
	hud_rect(track_x, track_y - 1 * scale, track_w, 2 * scale, UI_STROKE)
	hud_rect(track_x, track_y - 1 * scale, track_w * fill, 2 * scale, UI_ACCENT)
	// the grip: a small vertical bar at the fill edge
	hud_rect(track_x + track_w * fill - 1.5 * scale, track_y - 6 * scale, 3 * scale, 12 * scale, UI_TEXT)

	hud_text(
		x + w - UI_PAD * scale,
		ty,
		fmt.tprintf(fmt_str, value^),
		size,
		ui_mix(UI_TEXT_DIM, UI_TEXT, t),
		.Right,
	)

	changed := value^ != old
	if changed && ui.active_id != id do audio_emit({kind = .Ui_Click, local = true})
	return changed
}

@(private = "file")
math_round_to :: proc(v, step: f32) -> f32 {
	steps := v / step
	return step * f32(int(steps + (steps > 0 ? 0.5 : -0.5)))
}

// A row of equal-width tabs; the active one carries the accent underline.
// Returns true when the active tab changed.
ui_tab_bar :: proc(x, y, w, h: f32, tabs: []string, active: ^int, id_extra := 0) -> bool {
	scale := hud_scale()
	tab_w := w / f32(len(tabs))
	changed := false

	for tab, i in tabs {
		tx := x + f32(i) * tab_w
		hovered, t := ui_hot(ui_id(tab, id_extra + i), tx, y, tab_w, h)
		is_active := i == active^

		size := hud_font_size(UI_LABEL * scale)
		color := is_active ? UI_TEXT : ui_mix(UI_TEXT_DIM, UI_TEXT, t)
		hud_text(
			tx + tab_w * 0.5,
			y + (h - size) * 0.5,
			tab,
			size,
			color,
			.Center,
			tracking = size * 0.14,
		)

		if is_active {
			uw := tab_w * 0.6
			hud_rect(tx + (tab_w - uw) * 0.5, y + h - 2 * scale, uw, 2 * scale, UI_ACCENT)
		} else if t > 0.01 {
			uw := tab_w * 0.6 * ease_out_cubic(t)
			hud_rect(tx + (tab_w - uw) * 0.5, y + h - 2 * scale, uw, 2 * scale, ui_fade(UI_TEXT_DIM, t))
		}

		if ui_clicked(hovered) && !is_active {
			active^ = i
			changed = true
		}
	}
	hud_rect(x, y + h - 1 * scale, w, 1 * scale, UI_STROKE)
	return changed
}

// A layout cursor for uniform rows; index doubles as the entrance stagger key.
Ui_List :: struct {
	x, y, w:    f32,
	row_h, gap: f32,
	index:      int,
}

ui_list_row :: proc(list: ^Ui_List) -> (x, y, w, h: f32) {
	x = list.x
	y = list.y + f32(list.index) * (list.row_h + list.gap)
	w = list.w
	h = list.row_h
	list.index += 1
	return
}
