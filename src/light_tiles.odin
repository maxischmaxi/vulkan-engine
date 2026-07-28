package main

import "core:math/linalg"
import vk "vendor:vulkan"

// Screen-space tiled light culling, the CPU half.
//
// The fragment loop in brdf.glsl used to walk every active light for every
// fragment -- 17 on a quiet frame, up to 64 with muzzle flashes, almost all of
// them too far away to contribute anything. Here each light's sphere is
// projected once per frame into a conservative screen rectangle and its bit set
// in every 64x64-pixel tile the rectangle touches; the shader then iterates
// only the set bits of its own tile.
//
// A mask rather than an index list because MAX_POINT_LIGHTS is exactly 64: two
// uints per tile, no counts, no overflow case. A light the mask includes but the
// pixel is too far from shades to zero through the radius check, so culling
// cannot change the image -- only how much work it costs. That is also why
// --no-light-cull exists: it writes every-light masks and must render the
// identical frame, which makes the culling A/B-testable in the benchmark.

// Pixels per tile edge at the reference resolution; doubled as needed so a huge
// window degrades to coarser culling instead of overflowing the fixed buffer.
LIGHT_TILE_SIZE :: u32(64)

// 4096 tiles covers 4K at 64 px. The buffer is allocated for this once, so a
// resize never reallocates or rewrites descriptors.
MAX_LIGHT_TILES :: 4096

LIGHT_TILES_BYTES :: vk.DeviceSize(MAX_LIGHT_TILES * size_of([2]u32))

Light_Tiles :: struct {
	buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
}

light_tiles: Light_Tiles

create_light_tiles :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		light_tiles.buffers[i], light_tiles.memories[i] = create_buffer(
			LIGHT_TILES_BYTES,
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				light_tiles.memories[i],
				0,
				LIGHT_TILES_BYTES,
				{},
				&light_tiles.mapped[i],
			),
		)
	}
}

destroy_light_tiles :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, light_tiles.memories[i])
		destroy_buffer(light_tiles.buffers[i], light_tiles.memories[i])
	}
}

// The tile grid for the current scene size. Deterministic from the extent, so
// the binning and the uniform buffer cannot disagree within a frame. The size
// is always a power of two and travels to the shader as a shift, because a
// dynamic integer division per fragment is real money on a weak GPU.
light_tile_grid :: proc() -> (tiles: [2]u32, tile_size, tile_shift: u32) {
	extent := scene_extent()
	tile_size = LIGHT_TILE_SIZE
	tile_shift = 6
	#assert(LIGHT_TILE_SIZE == 1 << 6)
	for {
		tiles.x = (extent.width + tile_size - 1) / tile_size
		tiles.y = (extent.height + tile_size - 1) / tile_size
		if tiles.x * tiles.y <= MAX_LIGHT_TILES do return
		tile_size *= 2
		tile_shift += 1
	}
}

update_light_tiles :: proc(frame: u32) {
	tiles, tile_size, _ := light_tile_grid()
	count := int(tiles.x * tiles.y)
	dst := ([^][2]u32)(light_tiles.mapped[frame])

	// same shader path, every bit set: the culling reduced to a no-op
	if cli.no_light_cull {
		all := full_mask(len(point_lights))
		for i in 0 ..< count do dst[i] = all
		return
	}

	for i in 0 ..< count do dst[i] = {}

	view := camera_view()
	half_w, half_h := camera_half_tangents(camera.fov_horizontal)
	extent := scene_extent()

	for light, index in point_lights {
		lo, hi, visible := light_tile_rect(light, view, half_w, half_h, extent, tile_size, tiles)
		if !visible do continue

		bit: [2]u32
		if index < 32 {
			bit.x = 1 << u32(index)
		} else {
			bit.y = 1 << u32(index - 32)
		}

		for ty in lo.y ..= hi.y {
			for tx in lo.x ..= hi.x {
				cell := &dst[ty * tiles.x + tx]
				cell.x |= bit.x
				cell.y |= bit.y
			}
		}
	}
}

// The first n bits, for the culling-off path.
@(private = "file")
full_mask :: proc(n: int) -> (mask: [2]u32) {
	switch {
	case n >= 64:
		mask = {max(u32), max(u32)}
	case n >= 32:
		mask = {max(u32), (u32(1) << u32(n - 32)) - 1}
	case:
		mask = {(u32(1) << u32(n)) - 1, 0}
	}
	return
}

// Which tiles the light's sphere can reach, as an inclusive rectangle.
// Conservative throughout: the rect bounds the view-space box around the
// sphere, evaluated at both its nearest and farthest depth, so perspective can
// never shrink it past the truth. Too large only wastes shader iterations;
// too small would make a light pop at a tile edge.
@(private = "file")
light_tile_rect :: proc(
	light: Point_Light,
	view: linalg.Matrix4f32,
	half_w, half_h: f32,
	extent: vk.Extent2D,
	tile_size: u32,
	tiles: [2]u32,
) -> (
	lo, hi: [2]u32,
	visible: bool,
) {
	v := view * [4]f32{light.position.x, light.position.y, light.position.z, 1}
	depth := -v.z // the view looks down -z
	r := light.radius

	// wholly behind the eye
	if depth + r <= camera.near do return {}, {}, false

	// The eye is inside or nearly inside the sphere: the projection degenerates,
	// and the light genuinely can reach the whole screen.
	if depth - r <= camera.near do return {}, {tiles.x - 1, tiles.y - 1}, true

	d0 := depth - r // nearest slice, projects largest
	d1 := depth + r

	ndc_lo, ndc_hi: [2]f32
	x0 := v.x - r
	x1 := v.x + r
	ndc_lo.x = min(x0 / (d0 * half_w), x0 / (d1 * half_w))
	ndc_hi.x = max(x1 / (d0 * half_w), x1 / (d1 * half_w))

	// the projection's y row is negated for Vulkan, so view up is screen up
	y0 := -(v.y + r)
	y1 := -(v.y - r)
	ndc_lo.y = min(y0 / (d0 * half_h), y0 / (d1 * half_h))
	ndc_hi.y = max(y1 / (d0 * half_h), y1 / (d1 * half_h))

	if ndc_lo.x > 1 || ndc_hi.x < -1 || ndc_lo.y > 1 || ndc_hi.y < -1 do return {}, {}, false

	size := [2]f32{f32(extent.width), f32(extent.height)}
	px_lo := ([2]f32{clamp(ndc_lo.x, -1, 1), clamp(ndc_lo.y, -1, 1)} * 0.5 + 0.5) * size
	px_hi := ([2]f32{clamp(ndc_hi.x, -1, 1), clamp(ndc_hi.y, -1, 1)} * 0.5 + 0.5) * size

	lo.x = min(u32(px_lo.x) / tile_size, tiles.x - 1)
	lo.y = min(u32(px_lo.y) / tile_size, tiles.y - 1)
	hi.x = min(u32(px_hi.x) / tile_size, tiles.x - 1)
	hi.y = min(u32(px_hi.y) / tile_size, tiles.y - 1)
	return lo, hi, true
}
