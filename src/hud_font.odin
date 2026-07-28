package main

import "core:log"
import "core:math"
import "core:mem"
import vk "vendor:vulkan"

// The HUD's typeface, built into the binary rather than loaded. A shooter's HUD
// needs maybe forty characters -- digits, capitals and a handful of punctuation
// -- and a 5x7 bitmap covers all of them in 512 bytes. A real font would mean a
// TTF rasteriser, an asset to ship and a file that can go missing, for text that
// is never larger than forty pixels.
//
// The same reasoning the decals use: generate what you need instead of sampling
// something authored elsewhere.

FONT_GLYPH :: 8 // cell, in texels
FONT_INK :: 5 // columns a glyph actually draws into
FONT_ADVANCE :: 6 // cell columns from one glyph's origin to the next

FONT_FIRST :: 32 // space
FONT_COUNT :: 64 // through '_'
FONT_COLS :: 16
FONT_ROWS :: FONT_COUNT / FONT_COLS

FONT_ATLAS_W :: FONT_COLS * FONT_GLYPH
FONT_ATLAS_H :: FONT_ROWS * FONT_GLYPH

FONT_ADVANCE_RATIO :: f32(FONT_ADVANCE) / f32(FONT_GLYPH)
FONT_INK_RATIO :: f32(FONT_INK) / f32(FONT_GLYPH)

// One glyph per u64: eight rows of eight bits, the top row in the most
// significant byte and the leftmost column in the most significant bit of each.
// That ordering is the point -- a hex literal reads left to right and top to
// bottom exactly as the glyph is drawn, so these are editable by hand.
//
// Zeroes are characters this HUD has never needed. Filling one in is eight hex
// digits and no other change.
FONT_GLYPHS := [FONT_COUNT]u64 {
	0x0000000000000000, // space
	0x2020202020002000, // !
	0x0000000000000000, // "
	0x0000000000000000, // #
	0x2078A07028F02000, // $
	0x8890102040488800, // %
	0x0000000000000000, // &
	0x0000000000000000, // '
	0x1020404040201000, // (
	0x4020101010204000, // )
	0x0000000000000000, // *
	0x002020F820200000, // +
	0x0000000000202040, // ,
	0x0000007000000000, // -
	0x0000000000002000, // .
	0x0808102040808000, // /
	// A dot rather than the usual slash. At five columns a diagonal fills most
	// of the counter and the glyph reads as a 9.
	0x708888A888887000, // 0
	0x2060202020207000, // 1
	0x708808102040F800, // 2
	0xF00808700808F000, // 3
	0x10305090F8101000, // 4
	0xF880F00808887000, // 5
	0x304080F088887000, // 6
	0xF808102020202000, // 7
	0x7088887088887000, // 8
	0x7088887808106000, // 9
	0x0000200000200000, // :
	0x0000000000000000, // ;
	0x0000000000000000, // <
	0x0000F800F8000000, // =
	0x0000000000000000, // >
	0x0000000000000000, // ?
	0x0000000000000000, // @
	0x708888F888888800, // A
	0xF08888F08888F000, // B
	0x7088808080887000, // C
	0xE09088888890E000, // D
	0xF88080F08080F800, // E
	0xF88080F080808000, // F
	0x708880B888887000, // G
	0x888888F888888800, // H
	0x7020202020207000, // I
	0x3810101010906000, // J
	0x8890A0C0A0908800, // K
	0x808080808080F800, // L
	0x88D8A8A888888800, // M
	0x88C8A89888888800, // N
	0x7088888888887000, // O
	0xF08888F080808000, // P
	0x70888888A8906800, // Q
	0xF08888F0A0908800, // R
	0x7088807008887000, // S
	0xF820202020202000, // T
	0x8888888888887000, // U
	0x8888888888502000, // V
	0x888888A8A8D88800, // W
	0x8888502050888800, // X
	0x8888502020202000, // Y
	0xF80810204080F800, // Z
	0x7040404040407000, // [
	0x8080402010080800, // backslash
	0x7010101010107000, // ]
	0x2050880000000000, // ^
	0x00000000000000F8, // _
}

Hud_Font :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView,
	sampler: vk.Sampler,
}

hud_font: Hud_Font

// Unpacks the bit patterns into a coverage texture. Has to run before
// create_descriptor_sets, which is what points the HUD set at it.
create_hud_font :: proc() {
	pixels: [FONT_ATLAS_W * FONT_ATLAS_H]u8

	for glyph, index in FONT_GLYPHS {
		if glyph == 0 do continue

		origin_x := (index % FONT_COLS) * FONT_GLYPH
		origin_y := (index / FONT_COLS) * FONT_GLYPH

		for row in 0 ..< FONT_GLYPH {
			bits := u8((glyph >> uint(56 - row * 8)) & 0xFF)
			if bits == 0 do continue

			for col in 0 ..< FONT_GLYPH {
				if bits & (1 << uint(7 - col)) == 0 do continue
				pixels[(origin_y + row) * FONT_ATLAS_W + origin_x + col] = 255
			}
		}
	}

	size := vk.DeviceSize(len(pixels))
	staging, staging_memory := create_buffer(
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer destroy_buffer(staging, staging_memory)

	mapped: rawptr
	vk_check(vk.MapMemory(g.device, staging_memory, 0, size, {}, &mapped))
	mem.copy(mapped, raw_data(pixels[:]), len(pixels))
	vk.UnmapMemory(g.device, staging_memory)

	hud_font.image, hud_font.memory = create_image(
		FONT_ATLAS_W,
		FONT_ATLAS_H,
		1,
		.R8_UNORM,
		.OPTIMAL,
		{.TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
	)

	cmd := begin_single_time_commands()
	transition_image(
		cmd,
		hud_font.image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{},
		{.TRANSFER_WRITE},
	)
	end_single_time_commands(cmd)

	copy_buffer_to_image(staging, hud_font.image, FONT_ATLAS_W, FONT_ATLAS_H)

	cmd = begin_single_time_commands()
	transition_image(
		cmd,
		hud_font.image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.TRANSFER_WRITE},
		{.SHADER_READ},
	)
	end_single_time_commands(cmd)

	view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = hud_font.image,
		viewType = .D2,
		format = .R8_UNORM,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_check(vk.CreateImageView(g.device, &view_ci, nil, &hud_font.view))

	// NEAREST and no mips on purpose. Text is only ever drawn at whole multiples
	// of the cell, so every texel lands on an exact block of pixels; filtering
	// would soften edges that are meant to be hard.
	sampler_ci := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .NEAREST,
		minFilter     = .NEAREST,
		mipmapMode    = .NEAREST,
		addressModeU  = .CLAMP_TO_EDGE,
		addressModeV  = .CLAMP_TO_EDGE,
		addressModeW  = .CLAMP_TO_EDGE,
		compareOp     = .ALWAYS,
		maxLod        = 0,
		borderColor   = .INT_TRANSPARENT_BLACK,
		maxAnisotropy = 1,
	}
	vk_check(vk.CreateSampler(g.device, &sampler_ci, nil, &hud_font.sampler))

	log.infof("HUD font: {}x{} atlas, {} glyphs", FONT_ATLAS_W, FONT_ATLAS_H, FONT_COUNT)
}

destroy_hud_font :: proc() {
	vk.DestroySampler(g.device, hud_font.sampler, nil)
	vk.DestroyImageView(g.device, hud_font.view, nil)
	vk.DestroyImage(g.device, hud_font.image, nil)
	vk.FreeMemory(g.device, hud_font.memory, nil)
}

// ----------------------------------------------------------------------- text

Hud_Align :: enum {
	Left,
	Center,
	Right,
}

// Snapped to a whole multiple of the cell. Scaling a bitmap font by 2.6 gives
// some stems two pixels and their neighbours three, which reads as a wobble
// across a line of digits; integer multiples never do.
hud_font_size :: proc(size: f32) -> f32 {
	return max(FONT_GLYPH, math.round(size / FONT_GLYPH) * FONT_GLYPH)
}

// The ink, not the pen travel: the gap after the last glyph is not part of the
// word, and including it would put centred text half a gap off centre.
hud_text_width :: proc(text: string, size: f32) -> f32 {
	if len(text) == 0 do return 0
	px := hud_font_size(size)
	return f32(len(text) - 1) * px * FONT_ADVANCE_RATIO + px * FONT_INK_RATIO
}

// Returns where the pen ended up, so runs can be chained without measuring.
hud_text :: proc(
	x, y: f32,
	text: string,
	size: f32,
	color: [4]f32,
	align: Hud_Align = .Left,
) -> f32 {
	px := hud_font_size(size)
	advance := px * FONT_ADVANCE_RATIO

	pen := math.round(x)
	switch align {
	case .Left:
	case .Center:
		pen = math.round(x - hud_text_width(text, px) * 0.5)
	case .Right:
		pen = math.round(x - hud_text_width(text, px))
	}
	top := math.round(y)

	for i in 0 ..< len(text) {
		c := text[i]
		// The atlas holds capitals only, so lowercase is folded onto them rather
		// than dropped.
		if c >= 'a' && c <= 'z' do c -= 32

		index := int(c) - FONT_FIRST
		if index >= 0 && index < FONT_COUNT && FONT_GLYPHS[index] != 0 {
			col := f32(index % FONT_COLS)
			row := f32(index / FONT_COLS)
			hud_quad(
				{
					rect = {pen, top, px, px},
					uv = {
						col / FONT_COLS,
						row / FONT_ROWS,
						(col + 1) / FONT_COLS,
						(row + 1) / FONT_ROWS,
					},
					color = color,
					params = {0, 1, 0, 0},
				},
			)
		}
		pen += advance
	}
	return pen
}

// A dark copy underneath, for the same reason the crosshair has an outline: HUD
// text sits over a sandstone map that is bright in some places and shadowed in
// others, and one colour cannot stay legible against both.
hud_text_shadow :: proc(
	x, y: f32,
	text: string,
	size: f32,
	color: [4]f32,
	align: Hud_Align = .Left,
) -> f32 {
	px := hud_font_size(size)
	// A fraction of a texel, not a whole one. Offsetting by a full font pixel is
	// six screen pixels at HUD sizes, which reads as the text printed twice.
	offset := max(1, math.round(px / 24))
	hud_text(x + offset, y + offset, text, px, {0, 0, 0, color.a * 0.7}, align)
	return hud_text(x, y, text, px, color, align)
}
