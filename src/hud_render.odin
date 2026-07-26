package main

import "core:math"
import vk "vendor:vulkan"

// Screen-space overlay. Currently just the crosshair, but it is the pass every
// future HUD element belongs in.

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

Hud_Renderer :: struct {
	pipeline: Pipeline,
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
		depth_format   = g.depth_format,
		samples        = g.msaa_samples,
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

destroy_hud_renderer :: proc() {
	destroy_pipeline(hud_renderer.pipeline)
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

record_hud_pass :: proc(cmd: vk.CommandBuffer) {
	vk.CmdBindPipeline(cmd, .GRAPHICS, hud_renderer.pipeline.pipeline)

	screen := [4]f32 {
		1.0 / f32(g.swapchain_extent.width),
		1.0 / f32(g.swapchain_extent.height),
		1, // no rotation
		0,
	}

	// A dark border underneath keeps the crosshair readable against a bright
	// wall, which a single-colour cross is not. It grows on all four sides,
	// tips included: a border that stops short of the tip leaves the thinnest,
	// hardest-to-see part of the cross without one.
	if crosshair.outline > 0 {
		grow := max(1, math.round(crosshair.outline * crosshair_scale()))
		draw_crosshair(
			cmd,
			{
				rects = crosshair_rects(crosshair, grow),
				color = {0, 0, 0, crosshair.color.a * 0.6},
				screen = screen,
			},
		)
	}

	draw_crosshair(
		cmd,
		{rects = crosshair_rects(crosshair, 0), color = crosshair.color, screen = screen},
	)

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
		draw_crosshair(
			cmd,
			{
				rects = crosshair_rects(marker, 0),
				color = {1.0, 0.95, 0.9, alpha},
				screen = rotated,
			},
		)
	}
}

// The crosshair never opens up, because there is nothing for it to report:
// trace_shot fires exactly along the view direction with no spread at all. A
// crosshair that breathed anyway would be describing an inaccuracy the weapon
// does not have.
