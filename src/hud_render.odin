package main

import "core:log"
import "core:math"
import "core:mem"
import "game"
import vk "vendor:vulkan"

// Screen-space overlay: the crosshair, and the batched rectangles every other
// HUD element is built from. What those rectangles say lives in hud.odin and
// minimap.odin -- this file only knows how to put one on screen.

// A full-screen pass with a procedural crosshair would be fewer lines, but it
// would rasterise two million fragments to light up a few hundred. Five
// rectangles generated from gl_VertexIndex need no vertex buffer at all and
// touch only the pixels they cover. Unused ones are left as zeroes and
// rasterise nothing, so the draw is the same size whatever the style asks for.
CROSSHAIR_RECTS :: 5
CROSSHAIR_VERTS :: CROSSHAIR_RECTS * 6

// Counter-strike sizes its crosshair against a 480-pixel-tall reference screen
// and rounds the result to whole pixels. Doing the same keeps it the same
// apparent size on a 900p window and on 4K, instead of shrinking to a speck on
// one of them.
CROSSHAIR_REFERENCE_HEIGHT :: f32(480)

// Scalars are packed into vec4s rather than listed individually: std430 aligns
// a vec4 to 16 bytes, so loose floats followed by a vec4 would put the colour at
// a different offset on each side. Whole vectors sidestep the question -- the
// same reason Frame_Uniforms is nothing but mat4s and vec4s.
Crosshair_Push :: struct {
	rects:  [CROSSHAIR_RECTS][4]f32, // x0, y0, x1, y1 in pixels, y downward
	color:  [4]f32,
	screen: [4]f32, // 1/width, 1/height, cos(rotation), sin(rotation)
}

// Comfortably under the 128 bytes Vulkan guarantees every implementation.
#assert(size_of(Crosshair_Push) == 112)
#assert(offset_of(Crosshair_Push, color) == 80)
#assert(offset_of(Crosshair_Push, screen) == 96)

// Every rectangle the HUD draws in one buffer. The crosshair keeps its own
// pipeline because it is generated from nothing at all; everything else -- the
// minimap, the panels, every glyph -- is an instance here.
MAX_HUD_QUADS :: 2048

// std430-compatible, and the layout the vertex attributes below describe.
Hud_Quad :: struct {
	rect:   [4]f32, // x, y, width, height in pixels, origin top left
	uv:     [4]f32, // u0, v0, u1, v1 in the glyph atlas
	color:  [4]f32,
	params: [4]f32, // rotation (radians), mode (0 solid, 1 glyph), corner radius (px), unused
}

#assert(size_of(Hud_Quad) == 64)
#assert(offset_of(Hud_Quad, uv) == 16)
#assert(offset_of(Hud_Quad, color) == 32)
#assert(offset_of(Hud_Quad, params) == 48)

// A run of quads sharing a scissor rectangle. Clipping the minimap to its box
// this way keeps the quads themselves ignorant of where they are allowed to
// land, which is what lets the minimap submit geometry that runs off the edge.
Hud_Range :: struct {
	first, count: u32,
	scissor:      vk.Rect2D,
}

Hud_Push :: struct {
	screen: [4]f32, // 1/width, 1/height, unused, unused
}

Hud_Renderer :: struct {
	pipeline:          Pipeline,
	quad_pipeline:     Pipeline,
	instance_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	instance_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	instance_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	quads:             [dynamic]Hud_Quad,
	ranges:            [dynamic]Hud_Range,
	// Start of the range still being filled, and the scissor it will carry.
	range_start:       u32,
	scissor:           vk.Rect2D,
	overflowed:        bool,
}

hud_renderer: Hud_Renderer

// Sizes are in reference pixels, so they mean the same thing at every
// resolution. These are the counter-strike defaults.
Crosshair_Style :: struct {
	size:      f32, // length of one arm
	thickness: f32,
	gap:       f32, // centre to the inner end of an arm
	outline:   f32, // 0 disables the dark border
	dot:       bool,
	t_style:   bool, // drop the top arm so it never covers what you aim at
	color:     [4]f32,
}

crosshair := Crosshair_Style {
	size      = 5, // 11 px arms at 1080p, same as cl_crosshairsize 5
	thickness = 0.5, // rounds to a single pixel at 1080p
	gap       = 2,
	outline   = 0.5,
	dot       = false,
	t_style   = false,
	color     = {0.35, 1.0, 0.42, 1.0},
}

create_hud_pipeline :: proc() {
	push := []vk.PushConstantRange {
		{stageFlags = {.VERTEX}, offset = 0, size = size_of(Crosshair_Push)},
	}

	hud_renderer.pipeline = build_pipeline(
	{
		name           = "hud/crosshair",
		vert_spv       = CROSSHAIR_VERT_CODE,
		frag_spv       = CROSSHAIR_FRAG_CODE,
		push_constants = push,
		color_formats  = {g.swapchain_format},
		// The HUD is drawn in its own block after the scene has been resolved and
		// stretched: one sample, no depth buffer, at the window's own size.
		// sits on top of everything, and writing depth would be meaningless
		depth_test     = .Disabled,
		no_depth_write = true,
		blend          = .Alpha,
		// The quads wind both ways depending on which side of the centre they
		// fall on, so culling would drop half the cross.
		cull           = .None,
	},
	)
}

hud_quad_binding_descriptions :: proc() -> [1]vk.VertexInputBindingDescription {
	// No per-vertex buffer at all: the six corners come from gl_VertexIndex.
	return {{binding = 0, stride = size_of(Hud_Quad), inputRate = .INSTANCE}}
}

hud_quad_attribute_descriptions :: proc() -> [4]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32A32_SFLOAT, offset = 0},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Hud_Quad, uv)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Hud_Quad, color)),
		},
		{
			location = 3,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Hud_Quad, params)),
		},
	}
}

create_hud_quad_renderer :: proc() {
	// rewritten every frame, so host-visible and permanently mapped
	size := vk.DeviceSize(MAX_HUD_QUADS * size_of(Hud_Quad))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		hud_renderer.instance_buffers[i], hud_renderer.instance_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				hud_renderer.instance_memories[i],
				0,
				size,
				{},
				&hud_renderer.instance_mapped[i],
			),
		)
	}

	hud_renderer.quads = make([dynamic]Hud_Quad, 0, 512)
	hud_renderer.ranges = make([dynamic]Hud_Range, 0, 8)
}

create_hud_quad_pipeline :: proc() {
	bindings := hud_quad_binding_descriptions()
	attributes := hud_quad_attribute_descriptions()

	push := []vk.PushConstantRange{{stageFlags = {.VERTEX}, offset = 0, size = size_of(Hud_Push)}}

	hud_renderer.quad_pipeline = build_pipeline(
		{
			name           = "hud/quads",
			vert_spv       = HUD_QUAD_VERT_CODE,
			frag_spv       = HUD_QUAD_FRAG_CODE,
			bindings       = bindings[:],
			attributes     = attributes[:],
			set_layouts    = {descriptors.hud_layout},
			push_constants = push,
			color_formats  = {g.swapchain_format},
			// see create_hud_pipeline: its own block, one sample, no depth
			depth_test     = .Disabled,
			no_depth_write = true,
			blend          = .Alpha,
			// A rotated marker winds either way depending on its angle.
			cull           = .None,
		},
	)
}

destroy_hud_renderer :: proc() {

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, hud_renderer.instance_memories[i])
		destroy_buffer(hud_renderer.instance_buffers[i], hud_renderer.instance_memories[i])
	}

	delete(hud_renderer.quads)
	delete(hud_renderer.ranges)
}

// -------------------------------------------------------------- quad building

full_screen_scissor :: proc() -> vk.Rect2D {
	return {extent = g.swapchain_extent}
}

hud_begin_frame :: proc() {
	clear(&hud_renderer.quads)
	clear(&hud_renderer.ranges)
	hud_renderer.range_start = 0
	hud_renderer.scissor = full_screen_scissor()
	hud_renderer.overflowed = false
}

@(private = "file")
flush_range :: proc() {
	count := u32(len(hud_renderer.quads)) - hud_renderer.range_start
	if count == 0 do return

	append(
		&hud_renderer.ranges,
		Hud_Range{first = hud_renderer.range_start, count = count, scissor = hud_renderer.scissor},
	)
	hud_renderer.range_start += count
}

// Closes the frame's last range. Nothing may be submitted after this until the
// next hud_begin_frame.
hud_end_frame :: proc() {
	flush_range()
}

hud_quad :: proc(quad: Hud_Quad) {
	// Dropping the overflow rather than panicking: a HUD that loses its last few
	// glyphs is a bug worth a log line, not worth taking the game down for.
	if len(hud_renderer.quads) >= MAX_HUD_QUADS {
		if !hud_renderer.overflowed {
			hud_renderer.overflowed = true
			log.warnf("HUD exceeded {} quads, dropping the rest of the frame", MAX_HUD_QUADS)
		}
		return
	}
	append(&hud_renderer.quads, quad)
}

// Pixel-snapped: a bitmap glyph or a one-pixel rule landing on a half pixel is
// blurred by the MSAA resolve, and the whole HUD reads as slightly out of focus.
hud_rect :: proc(x, y, w, h: f32, color: [4]f32, radius: f32 = 0) {
	if w <= 0 || h <= 0 || color.a <= 0 do return

	x0 := math.round(x)
	y0 := math.round(y)
	hud_quad(
		{
			rect = {x0, y0, max(1, math.round(x + w) - x0), max(1, math.round(y + h) - y0)},
			color = color,
			params = {0, 0, radius, 0},
		},
	)
}

// Centred on cx/cy and turned about that point. Not snapped: a rotated edge
// lands between pixels whatever we do, and MSAA already covers it.
hud_rect_rotated :: proc(cx, cy, w, h, rotation: f32, color: [4]f32) {
	if w <= 0 || h <= 0 || color.a <= 0 do return
	hud_quad(
		{rect = {cx - w * 0.5, cy - h * 0.5, w, h}, color = color, params = {rotation, 0, 0, 0}},
	)
}

// A hollow rectangle, drawn as four rules so the middle stays transparent.
hud_frame :: proc(x, y, w, h, thickness: f32, color: [4]f32) {
	t := max(1, math.round(thickness))
	hud_rect(x, y, w, t, color)
	hud_rect(x, y + h - t, w, t, color)
	hud_rect(x, y + t, t, h - 2 * t, color)
	hud_rect(x + w - t, y + t, t, h - 2 * t, color)
}

// Everything submitted until hud_clip_end is clipped to this box.
hud_clip_begin :: proc(x, y, w, h: f32) {
	flush_range()

	width := i32(g.swapchain_extent.width)
	height := i32(g.swapchain_extent.height)

	x0 := clamp(i32(math.floor(x)), 0, width)
	y0 := clamp(i32(math.floor(y)), 0, height)
	x1 := clamp(i32(math.ceil(x + w)), x0, width)
	y1 := clamp(i32(math.ceil(y + h)), y0, height)

	hud_renderer.scissor = {
		offset = {x0, y0},
		extent = {u32(x1 - x0), u32(y1 - y0)},
	}
}

hud_clip_end :: proc() {
	flush_range()
	hud_renderer.scissor = full_screen_scissor()
}

// Called once the frame's quads are complete and before any pass reads them.
upload_hud_quads :: proc(frame: u32) {
	count := len(hud_renderer.quads)
	if count == 0 do return

	dst := ([^]Hud_Quad)(hud_renderer.instance_mapped[frame])
	mem.copy(&dst[0], raw_data(hud_renderer.quads), count * size_of(Hud_Quad))
}

@(private = "file")
crosshair_scale :: proc() -> f32 {
	return f32(g.swapchain_extent.height) / CROSSHAIR_REFERENCE_HEIGHT
}

// Every edge comes out a whole pixel, so an arm is exactly `thickness` pixels
// wide at any window size and any thickness. Letting the shader work in NDC
// instead leaves the edges on half pixels whenever the window has an odd
// dimension, and MSAA turns a crisp line into a grey one. `grow` expands the
// rectangles on all four sides, which is how the outline is drawn.
@(private = "file")
crosshair_rects :: proc(style: Crosshair_Style, grow: f32) -> (rects: [CROSSHAIR_RECTS][4]f32) {
	scale := crosshair_scale()
	thick := max(1, math.round(style.thickness * scale))
	arm := max(1, math.round(style.size * scale))
	gap := max(0, math.round(style.gap * scale))

	// The centre of an even-sized window is a pixel boundary rather than a
	// pixel. The arm straddles it, and flooring keeps both axes agreeing on
	// which side the extra row goes when the thickness is odd.
	cx := math.floor(f32(g.swapchain_extent.width) * 0.5)
	cy := math.floor(f32(g.swapchain_extent.height) * 0.5)
	half := math.floor(thick * 0.5)

	x0, x1 := cx - half, cx - half + thick
	y0, y1 := cy - half, cy - half + thick

	// right, left, down, up -- Vulkan's y grows downward, so `down` is +y
	rects[0] = {cx + gap - grow, y0 - grow, cx + gap + arm + grow, y1 + grow}
	rects[1] = {cx - gap - arm - grow, y0 - grow, cx - gap + grow, y1 + grow}
	rects[2] = {x0 - grow, cy + gap - grow, x1 + grow, cy + gap + arm + grow}

	if !style.t_style {
		rects[3] = {x0 - grow, cy - gap - arm - grow, x1 + grow, cy - gap + grow}
	}
	if style.dot {
		rects[4] = {x0 - grow, y0 - grow, x1 + grow, y1 + grow}
	}
	return
}

@(private = "file")
draw_crosshair :: proc(cmd: vk.CommandBuffer, push: Crosshair_Push) {
	push := push
	vk.CmdPushConstants(
		cmd,
		hud_renderer.pipeline.layout,
		{.VERTEX},
		0,
		size_of(Crosshair_Push),
		&push,
	)
	vk.CmdDraw(cmd, CROSSHAIR_VERTS, 1, 0, 0)
}

record_hud_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	// Damage feedback under everything, and deliberately outside the F12 gate:
	// it is gameplay information like the crosshair, not HUD chrome. Unlike
	// the crosshair it stays while dead -- the killing blow's heading is
	// exactly what the death screen should still show.
	if scene_playing() && !scene.paused {
		record_damage_indicator(cmd)
	}

	record_hud_quads(cmd, frame)

	// The crosshair belongs to the weapon, not the overlay: hiding the HUD for a
	// screenshot should not take away what you are aiming with. Dying should --
	// and so should any screen that is not the game itself, the buy menu
	// included.
	if scene_playing() &&
	   !scene.paused &&
	   player.alive &&
	   !buy_menu.open &&
	   !weapon_state.zoom_active {
		record_crosshair(cmd)
	}
}

@(private = "file")
record_hud_quads :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if len(hud_renderer.ranges) == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, hud_renderer.quad_pipeline.pipeline)
	bind_hud_set(cmd, hud_renderer.quad_pipeline.layout)

	offset := vk.DeviceSize(0)
	vk.CmdBindVertexBuffers(cmd, 0, 1, &hud_renderer.instance_buffers[frame], &offset)

	push := Hud_Push {
		screen = {1.0 / f32(g.swapchain_extent.width), 1.0 / f32(g.swapchain_extent.height), 0, 0},
	}
	vk.CmdPushConstants(
		cmd,
		hud_renderer.quad_pipeline.layout,
		{.VERTEX},
		0,
		size_of(Hud_Push),
		&push,
	)

	for range in hud_renderer.ranges {
		if range.scissor.extent.width == 0 || range.scissor.extent.height == 0 do continue

		scissor := range.scissor
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		// firstInstance also offsets the instance attribute fetch, so a range is
		// a draw with no buffer rebinding.
		vk.CmdDraw(cmd, 6, range.count, 0, range.first)
	}

	// The pass set this once at the top; leaving it on the last minimap box
	// would clip every pass added after this one.
	full := full_screen_scissor()
	vk.CmdSetScissor(cmd, 0, 1, &full)
}

// How far the random stance cone reaches on screen, in the crosshair's
// reference pixels: the opened gap's edge sits where the cone's edge lands.
// Deterministic in the player's own stance, so it can be drawn client-side.
@(private = "file")
crosshair_bloom :: proc() -> f32 {
	inacc := game.inaccuracy_degrees(
		current_weapon(),
		player^,
		weapon_state.zoom_active,
		weapon_state.spray.progress,
	)
	if inacc <= 0 do return 0
	_, half_h := camera_half_tangents(camera.fov_horizontal)
	return math.tan(math.to_radians(inacc)) * (CROSSHAIR_REFERENCE_HEIGHT * 0.5) / half_h
}

@(private = "file")
record_crosshair :: proc(cmd: vk.CommandBuffer) {
	vk.CmdBindPipeline(cmd, .GRAPHICS, hud_renderer.pipeline.pipeline)

	screen := [4]f32 {
		1.0 / f32(g.swapchain_extent.width),
		1.0 / f32(g.swapchain_extent.height),
		1, // no rotation
		0,
	}

	// Moving or airborne, the gap opens to the random cone the shot would be
	// thrown into; planted, it closes back to the authored style.
	style := crosshair
	style.gap += crosshair_bloom()

	// A dark border underneath keeps the crosshair readable against a bright
	// wall, which a single-colour cross is not. It grows on all four sides,
	// tips included: a border that stops short of the tip leaves the thinnest,
	// hardest-to-see part of the cross without one.
	if style.outline > 0 {
		grow := max(1, math.round(style.outline * crosshair_scale()))
		draw_crosshair(
			cmd,
			{
				rects = crosshair_rects(style, grow),
				color = {0, 0, 0, style.color.a * 0.6},
				screen = screen,
			},
		)
	}

	draw_crosshair(cmd, {rects = crosshair_rects(style, 0), color = style.color, screen = screen})

	// Without sound, this X is the only confirmation that a shot connected. Same
	// five rectangles, turned a quarter of a right angle so it reads as a
	// different shape rather than as the crosshair growing.
	alpha := hit_marker_alpha()
	if alpha > 0 {
		marker := crosshair
		marker.size = 7
		marker.gap = 2.5
		marker.thickness = 0.75
		marker.dot = false
		marker.t_style = false

		rotated := screen
		rotated.z = math.SQRT_TWO * 0.5
		rotated.w = math.SQRT_TWO * 0.5

		if marker.outline > 0 {
			grow := max(1, math.round(marker.outline * crosshair_scale()))
			draw_crosshair(
				cmd,
				{
					rects = crosshair_rects(marker, grow),
					color = {0, 0, 0, alpha * 0.6},
					screen = rotated,
				},
			)
		}
		// Red when the hit was fatal. A kill and a graze feel identical without
		// sound, and the count in the corner is too far from the centre to read
		// mid-fight.
		tint :=
			weapon_state.hit_killed ? [4]f32{1.0, 0.32, 0.28, alpha} : [4]f32{1.0, 0.95, 0.9, alpha}
		draw_crosshair(cmd, {rects = crosshair_rects(marker, 0), color = tint, screen = rotated})
	}
}

// The crosshair reports exactly one thing: the random stance cone (bloom on
// the gap, above). The spray pattern and the pellet rosette stay unreported
// on purpose -- both are deterministic, identical every burst, and a
// crosshair that breathed with them would dress skill up as variance.
