package main

import "core:log"
import "core:mem"
import "core:thread"
import vk "vendor:vulkan"

// BC5 compression for the normal and ORM arrays, done at load time on the CPU.
//
// Both arrays only ever carry two channels the shader reads -- a tangent-space
// normal's x and y (z is reconstructed in world.frag), and occlusion plus
// roughness (metallic is a per-material constant). BC5 stores exactly two
// channels at 1 byte per texel against RGBA8's 4, and the win is not VRAM, it
// is texture cache hit rate: three fetches per fragment at a quarter the
// footprint.
//
// BC formats cannot be blitted into, so the mip chain the GPU used to build is
// computed here instead: box-filter each level on the CPU, encode every level,
// upload the lot in one go. Albedo stays RGBA8_SRGB -- a hand-rolled BC1/BC7
// encoder is where the quality risk lives, and it is the one map the player
// actually looks at.

BC5_FORMAT :: vk.Format.BC5_UNORM_BLOCK

// One 4x4 block of one channel: two endpoints, sixteen 3-bit indices.
// out[0] > out[1] selects the 8-value palette, which this encoder always uses.
@(private = "file")
encode_bc4_block :: proc(vals: ^[16]u8, out: []byte) {
	lo, hi := vals[0], vals[0]
	for v in vals {
		lo = min(lo, v)
		hi = max(hi, v)
	}
	out[0] = hi
	out[1] = lo

	if hi == lo {
		for i in 2 ..< 8 do out[i] = 0
		return
	}

	span := int(hi) - int(lo)
	bits: u64
	for v, i in vals {
		// nearest of the 8 evenly spaced palette entries between lo and hi
		s := ((int(v) - int(lo)) * 7 + span / 2) / span
		idx: u64
		switch s {
		case 7:
			idx = 0 // hi itself
		case 0:
			idx = 1 // lo itself
		case:
			idx = u64(8 - s)
		}
		bits |= idx << (u64(i) * 3)
	}
	for i in 0 ..< 6 {
		out[2 + i] = u8(bits >> (u64(i) * 8))
	}
}

// One mip level of two-channel data into BC5 blocks. Partial edge blocks
// repeat the border texel, which matches what REPEAT sampling shows anyway.
@(private = "file")
encode_bc5_level :: proc(rg: []byte, w, h: int, dst: []byte) {
	bw := (w + 3) / 4
	bh := (h + 3) / 4

	for by in 0 ..< bh {
		for bx in 0 ..< bw {
			r_vals, g_vals: [16]u8
			for py in 0 ..< 4 {
				sy := min(by * 4 + py, h - 1)
				for px in 0 ..< 4 {
					sx := min(bx * 4 + px, w - 1)
					si := (sy * w + sx) * 2
					r_vals[py * 4 + px] = rg[si]
					g_vals[py * 4 + px] = rg[si + 1]
				}
			}
			off := (by * bw + bx) * 16
			encode_bc4_block(&r_vals, dst[off:off + 8])
			encode_bc4_block(&g_vals, dst[off + 8:off + 16])
		}
	}
}

// Plain 2x2 box filter, the same operation the GPU blit chain performed.
@(private = "file")
downsample_rg :: proc(src: []byte, sw, sh: int, dst: []byte, dw, dh: int) {
	for y in 0 ..< dh {
		y0 := min(y * 2, sh - 1)
		y1 := min(y * 2 + 1, sh - 1)
		for x in 0 ..< dw {
			x0 := min(x * 2, sw - 1)
			x1 := min(x * 2 + 1, sw - 1)
			for c in 0 ..< 2 {
				sum :=
					int(src[(y0 * sw + x0) * 2 + c]) +
					int(src[(y0 * sw + x1) * 2 + c]) +
					int(src[(y1 * sw + x0) * 2 + c]) +
					int(src[(y1 * sw + x1) * 2 + c])
				dst[(y * dw + x) * 2 + c] = u8((sum + 2) / 4)
			}
		}
	}
}

@(private = "file")
mip_dims :: proc(width, height: u32, level: u32) -> (w, h: int) {
	return max(int(width >> level), 1), max(int(height >> level), 1)
}

@(private = "file")
bc5_level_bytes :: proc(width, height: u32, level: u32) -> int {
	w, h := mip_dims(width, height, level)
	return ((w + 3) / 4) * ((h + 3) / 4) * 16
}

@(private = "file")
bc5_layer_bytes :: proc(width, height, mip_levels: u32) -> int {
	total := 0
	for m in 0 ..< mip_levels do total += bc5_level_bytes(width, height, m)
	return total
}

@(private = "file")
Bc_Job :: struct {
	first, last:   int, // layer range
	width, height: u32,
	mip_levels:    u32,
	src:           []byte, // RGBA8, all layers
	dst:           []byte, // BC5, all layers and mips
}

@(private = "file")
bc_encode_worker :: proc(job: ^Bc_Job) {
	w := int(job.width)
	h := int(job.height)
	layer_stride := bc5_layer_bytes(job.width, job.height, job.mip_levels)

	// enough for the largest level plus the one below it
	rg := make([]byte, w * h * 2 + (w / 2) * (h / 2) * 2 + 8)
	defer delete(rg)
	current := rg[:w * h * 2]
	next := rg[w * h * 2:]

	for layer in job.first ..< job.last {
		base := layer * w * h * 4
		for i in 0 ..< w * h {
			current[i * 2] = job.src[base + i * 4]
			current[i * 2 + 1] = job.src[base + i * 4 + 1]
		}

		offset := layer * layer_stride
		cw, ch := w, h
		for m in 0 ..< job.mip_levels {
			level := bc5_level_bytes(job.width, job.height, m)
			encode_bc5_level(current[:cw * ch * 2], cw, ch, job.dst[offset:offset + level])
			offset += level

			if m + 1 == job.mip_levels do break
			nw, nh := mip_dims(job.width, job.height, m + 1)
			downsample_rg(current, cw, ch, next, nw, nh)
			current, next = next, current
			cw, ch = nw, nh
		}
	}
}

// The BC5 counterpart of upload_texture_array: same result state -- every
// level and layer in SHADER_READ_ONLY_OPTIMAL -- but the mips arrive from the
// staging buffer instead of a blit chain.
upload_texture_array_bc5 :: proc(
	pixels: []byte,
	width, height: u32,
	layers: u32,
	mip_levels: u32,
) -> (
	result: Texture_Array,
) {
	layer_stride := bc5_layer_bytes(width, height, mip_levels)
	total := layer_stride * int(layers)
	compressed := make([]byte, total)
	defer delete(compressed)

	per_worker := (int(layers) + 8 - 1) / 8
	worker_count := (int(layers) + per_worker - 1) / per_worker
	jobs := make([]Bc_Job, worker_count, context.temp_allocator)
	threads := make([]^thread.Thread, worker_count, context.temp_allocator)
	for i in 0 ..< worker_count {
		jobs[i] = Bc_Job {
			first      = i * per_worker,
			last       = min((i + 1) * per_worker, int(layers)),
			width      = width,
			height     = height,
			mip_levels = mip_levels,
			src        = pixels,
			dst        = compressed,
		}
		threads[i] = thread.create_and_start_with_poly_data(
			&jobs[i],
			bc_encode_worker,
			g.odin_context,
		)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	staging_buffer, staging_memory := create_buffer(
		vk.DeviceSize(total),
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vk.FreeMemory(g.device, staging_memory, nil)
	defer vk.DestroyBuffer(g.device, staging_buffer, nil)

	mapped: rawptr
	vk_check(vk.MapMemory(g.device, staging_memory, 0, vk.DeviceSize(total), {}, &mapped))
	mem.copy(mapped, raw_data(compressed), total)
	vk.UnmapMemory(g.device, staging_memory)

	result.image, result.memory = create_image(
		width,
		height,
		mip_levels,
		BC5_FORMAT,
		.OPTIMAL,
		{.TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
		layers,
	)

	regions := make(
		[dynamic]vk.BufferImageCopy,
		0,
		int(layers * mip_levels),
		context.temp_allocator,
	)
	for layer in 0 ..< layers {
		offset := int(layer) * layer_stride
		for m in 0 ..< mip_levels {
			w, h := mip_dims(width, height, m)
			append(
				&regions,
				vk.BufferImageCopy {
					bufferOffset = vk.DeviceSize(offset),
					imageSubresource = {
						aspectMask = {.COLOR},
						mipLevel = m,
						baseArrayLayer = layer,
						layerCount = 1,
					},
					imageExtent = {u32(w), u32(h), 1},
				},
			)
			offset += bc5_level_bytes(width, height, m)
		}
	}

	cmd := begin_single_time_commands()
	transition_image(
		cmd,
		result.image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{},
		{.TRANSFER_WRITE},
		0,
		mip_levels,
		{.COLOR},
		0,
		layers,
	)
	vk.CmdCopyBufferToImage(
		cmd,
		staging_buffer,
		result.image,
		.TRANSFER_DST_OPTIMAL,
		u32(len(regions)),
		raw_data(regions),
	)
	transition_image(
		cmd,
		result.image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		0,
		mip_levels,
		{.COLOR},
		0,
		layers,
	)
	end_single_time_commands(cmd)

	view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = result.image,
		viewType = .D2_ARRAY,
		format = BC5_FORMAT,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = layers,
		},
	}
	vk_check(vk.CreateImageView(g.device, &view_ci, nil, &result.view))

	log.infof(
		"Texture array: BC5, {} layers, {} mips, {:.1f} MB",
		layers,
		mip_levels,
		f64(total) / (1024 * 1024),
	)
	return
}
