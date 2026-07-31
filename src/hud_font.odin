package main

import "core:c"
import "core:log"
import "core:math"
import "core:mem"
import stbtt "vendor:stb/truetype"
import vk "vendor:vulkan"

// The HUD's typefaces, embedded in the binary and baked into one SDF atlas at
// startup. #load keeps the old "no asset can go missing" property: the build
// fails if the TTF is absent, the shipped binary carries its own type.
//
// Two faces of the same family: Display carries headings, buttons and every
// number; Body carries descriptions and small print. `size` means cap height
// and `y` is the top of that cap line -- the semantics every call site was
// authored against when glyphs were 8x8 cells.

@(private = "file")
FONT_DISPLAY_TTF := #load("../fonts/Rajdhani-SemiBold.ttf")
@(private = "file")
FONT_BODY_TTF := #load("../fonts/Rajdhani-Regular.ttf")

FONT_ATLAS_SIZE :: 1024
FONT_BAKE_PX :: 64 // bake height; SDFs downscale well, upscales soften slowly
FONT_SDF_PAD :: 6 // texels of distance field around each glyph
FONT_SDF_EDGE :: 128 // atlas value at the glyph outline
// One bake pixel of distance per (128/6) atlas values: the field saturates
// exactly at the padding edge, wasting none of the 8-bit range.
FONT_SDF_SCALE :: f32(FONT_SDF_EDGE) / f32(FONT_SDF_PAD)

// Text shadows draw the same string fattened by ~one bake pixel and dark; the
// bias rides in params.w of every glyph quad.
FONT_SHADOW_BIAS :: f32(0.08)

// ASCII plus the German set, so persona names and future copy survive. The
// bake walks this string; adding a codepoint is adding it here.
@(private = "file")
FONT_GLYPH_SET :: " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~äöüÄÖÜß"

Ui_Font :: enum u8 {
	Display,
	Body,
}

@(private = "file")
Glyph :: struct {
	uv:      [4]f32, // u0, v0, u1, v1 in the atlas
	offset:  [2]f32, // pen (at baseline) to bitmap top-left, bake px
	size:    [2]f32, // bitmap extent, bake px
	advance: f32, // bake px
}

@(private = "file")
Font_Face :: struct {
	info:          stbtt.fontinfo,
	glyphs:        map[rune]Glyph,
	kern:          map[u64]f32, // (prev << 32 | cur) -> bake px; empty for GPOS-only fonts
	cap_height:    f32, // bake px; the scale everything draws against
	digit_advance: f32, // one advance for all digits, so timers never jitter
	space_advance: f32, // fallback advance for runes outside the set
}

Hud_Font :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView,
	sampler: vk.Sampler,
}

hud_font: Hud_Font

@(private = "file")
faces: [Ui_Font]Font_Face

// Bakes both faces into one atlas. Has to run before create_descriptor_sets,
// which is what points the HUD set at it.
create_hud_font :: proc() {
	pixels := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE)
	defer delete(pixels)

	// a shelf packer is plenty for ~200 same-height glyphs
	shelf_x, shelf_y, shelf_h: int

	ttfs := [Ui_Font][]u8 {
		.Display = FONT_DISPLAY_TTF,
		.Body    = FONT_BODY_TTF,
	}

	glyph_count := 0
	for &face, which in faces {
		if !stbtt.InitFont(&face.info, raw_data(ttfs[which]), 0) {
			log.panicf("HUD font: InitFont failed for {}", which)
		}
		scale := stbtt.ScaleForPixelHeight(&face.info, FONT_BAKE_PX)

		// cap height from 'H': the box top above the baseline
		x0, y0, x1, y1: c.int
		stbtt.GetCodepointBox(&face.info, 'H', &x0, &y0, &x1, &y1)
		face.cap_height = f32(y1) * scale

		for r in FONT_GLYPH_SET {
			adv, lsb: c.int
			stbtt.GetCodepointHMetrics(&face.info, r, &adv, &lsb)

			glyph := Glyph {
				advance = f32(adv) * scale,
			}

			w, h, xoff, yoff: c.int
			sdf := stbtt.GetCodepointSDF(
				&face.info,
				scale,
				c.int(r),
				FONT_SDF_PAD,
				FONT_SDF_EDGE,
				FONT_SDF_SCALE,
				&w,
				&h,
				&xoff,
				&yoff,
			)
			if sdf != nil {
				defer stbtt.FreeSDF(sdf, nil)

				if shelf_x + int(w) + 1 > FONT_ATLAS_SIZE {
					shelf_x = 0
					shelf_y += shelf_h + 1
					shelf_h = 0
				}
				if shelf_y + int(h) + 1 > FONT_ATLAS_SIZE {
					log.errorf("HUD font: atlas overflow at {} '{}'", which, r)
					break
				}

				for row in 0 ..< int(h) {
					dst := (shelf_y + row) * FONT_ATLAS_SIZE + shelf_x
					mem.copy(&pixels[dst], sdf[row * int(w):], int(w))
				}

				glyph.uv = {
					f32(shelf_x) / FONT_ATLAS_SIZE,
					f32(shelf_y) / FONT_ATLAS_SIZE,
					f32(shelf_x + int(w)) / FONT_ATLAS_SIZE,
					f32(shelf_y + int(h)) / FONT_ATLAS_SIZE,
				}
				glyph.offset = {f32(xoff), f32(yoff)}
				glyph.size = {f32(w), f32(h)}

				shelf_x += int(w) + 1
				shelf_h = max(shelf_h, int(h))
			}

			face.glyphs[r] = glyph
			glyph_count += 1
		}

		for d in '0' ..= '9' {
			face.digit_advance = max(face.digit_advance, face.glyphs[d].advance)
		}
		face.space_advance = face.glyphs[' '].advance

		// stbtt reads only the legacy kern table -- often empty for Google
		// fonts. Prebaking keeps the draw loop free of C calls either way.
		for a in FONT_GLYPH_SET {
			for b in FONT_GLYPH_SET {
				k := stbtt.GetCodepointKernAdvance(&face.info, a, b)
				if k != 0 {
					face.kern[u64(a) << 32 | u64(b)] = f32(k) * scale
				}
			}
		}
	}

	upload_font_atlas(pixels)
	log.infof(
		"HUD font: {}x{} SDF atlas, {} glyphs, {} kern pairs",
		FONT_ATLAS_SIZE,
		FONT_ATLAS_SIZE,
		glyph_count,
		len(faces[.Display].kern) + len(faces[.Body].kern),
	)
}

@(private = "file")
upload_font_atlas :: proc(pixels: []u8) {
	size := vk.DeviceSize(len(pixels))
	staging, staging_memory := create_buffer(
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer destroy_buffer(staging, staging_memory)

	mapped: rawptr
	vk_check(vk.MapMemory(g.device, staging_memory, 0, size, {}, &mapped))
	mem.copy(mapped, raw_data(pixels), len(pixels))
	vk.UnmapMemory(g.device, staging_memory)

	hud_font.image, hud_font.memory = create_image(
		FONT_ATLAS_SIZE,
		FONT_ATLAS_SIZE,
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

	copy_buffer_to_image(staging, hud_font.image, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)

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

	// LINEAR, unlike the old bitmap font: the SDF is meant to be interpolated,
	// the smoothstep in the shader is what keeps edges crisp.
	sampler_ci := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .LINEAR,
		minFilter     = .LINEAR,
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
}

destroy_hud_font :: proc() {
	for &face in faces {
		delete(face.glyphs)
		delete(face.kern)
	}
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

// The bitmap font quantised sizes to its cell; the SDF scales freely. Kept as
// the one place a floor on text size lives.
hud_font_size :: proc(size: f32) -> f32 {
	return max(8, size)
}

@(private = "file")
is_digit :: proc(r: rune) -> bool {
	return r >= '0' && r <= '9'
}

// Pen travel including tracking, which is what alignment needs. `size` is cap
// height, like everywhere.
hud_text_width :: proc(text: string, size: f32, tracking: f32 = 0, font: Ui_Font = .Display) -> f32 {
	face := &faces[font]
	draw_scale := size / face.cap_height

	width: f32
	prev: rune
	for r in text {
		glyph, ok := face.glyphs[r]
		advance := ok ? glyph.advance : face.space_advance
		if is_digit(r) do advance = face.digit_advance
		if prev != 0 {
			width += tracking
			if !is_digit(prev) && !is_digit(r) {
				if k, has := face.kern[u64(prev) << 32 | u64(r)]; has do width += k * draw_scale
			}
		}
		width += advance * draw_scale
		prev = r
	}
	return width
}

// Whether a byte survives into the atlas. Sanitisers for external strings
// (Steam persona names) keep only these.
hud_font_has_glyph :: proc(c: u8) -> bool {
	return c >= 32 && c < 127
}

// Returns where the pen ended up, so runs can be chained without measuring.
// `y` is the top of the cap line; the baseline sits at y + size, descenders
// reach below it.
hud_text :: proc(
	x, y: f32,
	text: string,
	size: f32,
	color: [4]f32,
	align: Hud_Align = .Left,
	tracking: f32 = 0,
	font: Ui_Font = .Display,
) -> f32 {
	return draw_text(x, y, text, size, color, align, tracking, font, 0)
}

// A dark, slightly fattened copy underneath: HUD text sits over a sandstone
// map that is bright in some places and shadowed in others, and one colour
// cannot stay legible against both.
hud_text_shadow :: proc(
	x, y: f32,
	text: string,
	size: f32,
	color: [4]f32,
	align: Hud_Align = .Left,
	tracking: f32 = 0,
	font: Ui_Font = .Display,
) -> f32 {
	offset := max(1, math.round(size / 24))
	draw_text(
		x + offset,
		y + offset,
		text,
		size,
		{0, 0, 0, color.a * 0.7},
		align,
		tracking,
		font,
		FONT_SHADOW_BIAS,
	)
	return draw_text(x, y, text, size, color, align, tracking, font, 0)
}

@(private = "file")
draw_text :: proc(
	x, y: f32,
	text: string,
	size: f32,
	color: [4]f32,
	align: Hud_Align,
	tracking: f32,
	font: Ui_Font,
	edge_bias: f32,
) -> f32 {
	face := &faces[font]
	draw_scale := size / face.cap_height

	pen := math.round(x)
	switch align {
	case .Left:
	case .Center:
		pen = math.round(x - hud_text_width(text, size, tracking, font) * 0.5)
	case .Right:
		pen = math.round(x - hud_text_width(text, size, tracking, font))
	}
	baseline := math.round(y) + size

	prev: rune
	for r in text {
		glyph, ok := face.glyphs[r]
		if !ok {
			// outside the set (emoji personas): advance like a space
			pen += face.space_advance * draw_scale + (prev != 0 ? tracking : 0)
			prev = r
			continue
		}

		advance := glyph.advance
		digit := is_digit(r)
		if digit do advance = face.digit_advance

		if prev != 0 {
			pen += tracking
			if !digit && !is_digit(prev) {
				if k, has := face.kern[u64(prev) << 32 | u64(r)]; has do pen += k * draw_scale
			}
		}

		if glyph.size.x > 0 {
			// digits centre inside their fixed cell so 1 sits where 8 does
			slack := digit ? (face.digit_advance - glyph.advance) * 0.5 : 0
			hud_quad(
				{
					rect = {
						pen + (glyph.offset.x + slack) * draw_scale,
						baseline + glyph.offset.y * draw_scale,
						glyph.size.x * draw_scale,
						glyph.size.y * draw_scale,
					},
					uv = glyph.uv,
					color = color,
					params = {0, 1, 0, edge_bias},
				},
			)
		}

		pen += advance * draw_scale
		prev = r
	}
	return pen
}
