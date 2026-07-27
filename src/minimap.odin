package main

import "core:log"
import "core:math"

// The radar. Generated from the same brushes the map is built out of, so it can
// never disagree with the level -- there is no image to redraw when a wall
// moves, and a new map gets a radar for free.
//
// Fixed to north like counter-strike's default, centred on the player. A radar
// that turns with the view is easier to read for one heading and unreadable for
// every other one, because the map itself stops having a shape you can learn.

// Half the world visible across the box. The whole map is 104 m wide, which at
// radar size would put a player dot below one pixel.
MINIMAP_RANGE :: f32(34)

// A brush counts as layout if it is tall enough to be something you walk around
// rather than over. Height rather than a band of world z, because the map is
// stacked: CT-spawn's floor is over two metres up and A-site's platform higher
// still, and a fixed band would draw one storey and drop the next.
//
// The cut lands where it does on purpose. Floor slabs, roofs and single stair
// treads fall under it; walls, crates and platforms stand above it.
MINIMAP_MIN_HEIGHT :: f32(0.9)

// The ground plane is 104 x 104 m and would cover everything. Anything near that
// size is backdrop, not layout.
MINIMAP_MAX_AREA :: f32(2000)

// How long an enemy stays on the radar after line of sight is lost. Counter-
// strike keeps the last known position for a moment for the same reason: an
// enemy who vanishes the instant they step behind a doorframe tells you less
// than the game already knows.
MINIMAP_MEMORY :: f32(3.0)

Minimap_Cell :: struct {
	min, max: [2]f32,
	color:    [4]f32,
}

// What the player knows about one bot, which is not the same as where it is.
Minimap_Contact :: struct {
	position: [2]f32,
	age:      f32, // seconds since last seen; at MINIMAP_MEMORY it is forgotten
}

Minimap :: struct {
	cells:    [dynamic]Minimap_Cell,
	contacts: [BOT_COUNT]Minimap_Contact,
}

minimap: Minimap

init_minimap :: proc(brushes: []Brush) {
	minimap.cells = make([dynamic]Minimap_Cell, 0, len(brushes))

	for b in brushes {
		size := b.max - b.min
		if size.z < MINIMAP_MIN_HEIGHT do continue
		if size.x * size.y > MINIMAP_MAX_AREA do continue

		append(
			&minimap.cells,
			Minimap_Cell {
				min = {b.min.x, b.min.y},
				max = {b.max.x, b.max.y},
				color = minimap_color(Material_ID(b.material)),
			},
		)
	}

	for &contact in minimap.contacts {
		contact.age = MINIMAP_MEMORY
	}

	log.infof("Minimap: {} cells from {} brushes", len(minimap.cells), len(brushes))
}

destroy_minimap :: proc() {
	delete(minimap.cells)
}

// Enough separation to tell cover from walls at a glance, and no more. A radar
// that reproduces the map's palette is a small picture of the map, not a chart.
@(private = "file")
minimap_color :: proc(material: Material_ID) -> [4]f32 {
	#partial switch material {
	case .Crate:
		return {0.72, 0.55, 0.30, 1}
	case .Brick, .Brick_Alt:
		return {0.55, 0.50, 0.44, 1}
	case .Rock, .Rock_Alt:
		return {0.24, 0.25, 0.28, 1} // the outer shell, barely there
	case:
		return {0.46, 0.50, 0.55, 1}
	}
}

// Runs on the frame rather than the tick: how long ago something was seen is
// real-time feedback, like every other fade in the HUD.
// Line of sight is not asked again here. The bots cast that exact ray on every
// tick anyway, so the radar reads their answer: the same question, asked once at
// 64 Hz instead of twice at whatever the frame rate happens to be. It also makes
// the radar agree with what the AI knows, which is the more defensible rule --
// a bot that cannot see you should not be on your radar.
update_minimap :: proc(dt: f32) {
	for &contact, i in minimap.contacts {
		bot := bots[i]
		if !bot.alive || !player.alive {
			contact.age = MINIMAP_MEMORY
			continue
		}

		if bot.sees_player {
			contact.position = {bot.body.position.x, bot.body.position.y}
			contact.age = 0
			continue
		}
		contact.age = min(contact.age + dt, MINIMAP_MEMORY)
	}
}

// ------------------------------------------------------------------- drawing

Minimap_View :: struct {
	origin: [2]f32, // world point under the centre of the box
	center: [2]f32, // that centre, in pixels
	zoom:   f32, // pixels per metre
}

// North is up, so world y is negated: Vulkan's y grows downward and the world's
// grows north.
@(private = "file")
minimap_to_screen :: proc(view: Minimap_View, world: [2]f32) -> [2]f32 {
	return {
		view.center.x + (world.x - view.origin.x) * view.zoom,
		view.center.y - (world.y - view.origin.y) * view.zoom,
	}
}

// Draws the box at x/y. Everything inside is clipped to it, so cells may run off
// the edge without being trimmed first.
draw_minimap :: proc(x, y, size: f32) {
	scale := hud_scale()

	view := Minimap_View {
		origin = {player.body.position.x, player.body.position.y},
		center = {x + size * 0.5, y + size * 0.5},
		zoom   = size * 0.5 / MINIMAP_RANGE,
	}

	hud_rect(x, y, size, size, HUD_PANEL, radius = 4 * scale)

	hud_clip_begin(x, y, size, size)
	draw_minimap_cells(view)
	draw_minimap_contacts(view)
	draw_minimap_player(view)
	hud_clip_end()

	hud_frame(x, y, size, size, scale, {0.55, 0.60, 0.66, 0.5})

	// North marker, so a fixed orientation is stated rather than assumed.
	hud_text_shadow(view.center.x, y + 3 * scale, "N", 8 * scale, HUD_DIM, .Center)
}

@(private = "file")
draw_minimap_cells :: proc(view: Minimap_View) {
	// Only what the box can show. At 34 m across that is a fraction of the map,
	// and every rejected cell is an instance and a rasterised quad saved.
	reach := MINIMAP_RANGE + 4

	for cell in minimap.cells {
		if cell.max.x < view.origin.x - reach || cell.min.x > view.origin.x + reach do continue
		if cell.max.y < view.origin.y - reach || cell.min.y > view.origin.y + reach do continue

		// The screen's top left corner is the cell's north-west corner, because
		// the y axis flipped on the way here.
		top_left := minimap_to_screen(view, {cell.min.x, cell.max.y})
		bottom_right := minimap_to_screen(view, {cell.max.x, cell.min.y})

		hud_rect(
			top_left.x,
			top_left.y,
			max(1, bottom_right.x - top_left.x),
			max(1, bottom_right.y - top_left.y),
			cell.color,
		)
	}
}

@(private = "file")
draw_minimap_contacts :: proc(view: Minimap_View) {
	dot := max(3, math.round(4 * hud_scale()))

	for contact, i in minimap.contacts {
		if !bots[i].alive do continue

		position := contact.position
		alpha: f32 = 1

		if debug_active() {
			// A radar that only reports what you can already see is no help
			// while working on the bots themselves.
			position = {bots[i].body.position.x, bots[i].body.position.y}
			alpha = contact.age <= 0.001 ? 1 : 0.4
		} else {
			if contact.age >= MINIMAP_MEMORY do continue
			alpha = 1 - contact.age / MINIMAP_MEMORY
		}

		screen := minimap_to_screen(view, position)
		hud_rect(
			screen.x - dot * 0.5,
			screen.y - dot * 0.5,
			dot,
			dot,
			{0.92, 0.28, 0.26, alpha},
			radius = dot * 0.5,
		)
	}
}

@(private = "file")
draw_minimap_player :: proc(view: Minimap_View) {
	scale := hud_scale()

	// The arrow points up at rotation zero and yaw 90 is north, so the turn is
	// whatever is left between them.
	rotation := math.to_radians(90 - camera.yaw)
	color := player.alive ? [4]f32{0.35, 1.0, 0.42, 1} : [4]f32{0.55, 0.58, 0.62, 1}

	// A shaft and a square turned onto its corner. Cheaper than a mesh, and it
	// still reads as an arrow at eight pixels, which a thin triangle would not.
	hud_rect_rotated(view.center.x, view.center.y, 2 * scale, 9 * scale, rotation, color)

	heading := [2]f32{math.sin(rotation), -math.cos(rotation)}
	tip := view.center + heading * 4 * scale
	hud_rect_rotated(tip.x, tip.y, 4 * scale, 4 * scale, rotation + math.PI * 0.25, color)
}
