package main

import "core:image"
import "core:image/png"
import "core:log"
import "core:math"
import "core:mem"
import vk "vendor:vulkan"

TEXTURE_DATA :: #load("../textures/texture.png")

// PNG pixels are gamma-encoded, so an _SRGB format lets the GPU linearise on read
TEXTURE_FORMAT :: vk.Format.R8G8B8A8_SRGB

create_image :: proc(
	width, height, mip_levels: u32,
	format: vk.Format,
	tiling: vk.ImageTiling,
	usage: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	img: vk.Image,
	memory: vk.DeviceMemory,
) {
	image_ci := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width = width, height = height, depth = 1},
		mipLevels     = mip_levels,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = tiling,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(g.device, &image_ci, nil, &img))

	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g.device, img, &requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = find_memory_type(requirements.memoryTypeBits, properties),
	}
	vk_check(vk.AllocateMemory(g.device, &alloc_info, nil, &memory))
	vk_check(vk.BindImageMemory(g.device, img, memory, 0))

	return
}

copy_buffer_to_image :: proc(buffer: vk.Buffer, img: vk.Image, width, height: u32) {
	cmd := begin_single_time_commands()

	region := vk.BufferImageCopy {
		bufferOffset = 0,
		// zero means tightly packed, which is what the staging buffer holds
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {width, height, 1},
	}
	vk.CmdCopyBufferToImage(cmd, buffer, img, .TRANSFER_DST_OPTIMAL, 1, &region)

	end_single_time_commands(cmd)
}

// Halves the image repeatedly with linear blits. Every level walks
// TRANSFER_DST -> TRANSFER_SRC -> SHADER_READ_ONLY on its own.
generate_mipmaps :: proc(img: vk.Image, format: vk.Format, width, height: i32, mip_levels: u32) {
	format_props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(g.physical_device, format, &format_props)
	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Format {} does not support linear blitting, cannot generate mipmaps", format)
	}

	cmd := begin_single_time_commands()

	mip_width := width
	mip_height := height

	for i in 1 ..< mip_levels {
		// the level we read from must leave TRANSFER_DST first
		transition_image(
			cmd,
			img,
			.TRANSFER_DST_OPTIMAL,
			.TRANSFER_SRC_OPTIMAL,
			{.TRANSFER},
			{.TRANSFER},
			{.TRANSFER_WRITE},
			{.TRANSFER_READ},
			i - 1,
			1,
		)

		next_width := mip_width > 1 ? mip_width / 2 : 1
		next_height := mip_height > 1 ? mip_height / 2 : 1

		blit := vk.ImageBlit {
			srcSubresource = {
				aspectMask = {.COLOR},
				mipLevel = i - 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			srcOffsets = {{0, 0, 0}, {mip_width, mip_height, 1}},
			dstSubresource = {
				aspectMask = {.COLOR},
				mipLevel = i,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			dstOffsets = {{0, 0, 0}, {next_width, next_height, 1}},
		}
		vk.CmdBlitImage(
			cmd,
			img,
			.TRANSFER_SRC_OPTIMAL,
			img,
			.TRANSFER_DST_OPTIMAL,
			1,
			&blit,
			.LINEAR,
		)

		// source level is done being read, hand it to the shader
		transition_image(
			cmd,
			img,
			.TRANSFER_SRC_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER},
			{.FRAGMENT_SHADER},
			{.TRANSFER_READ},
			{.SHADER_READ},
			i - 1,
			1,
		)

		mip_width = next_width
		mip_height = next_height
	}

	// the smallest level was never blitted from, so it is still TRANSFER_DST
	transition_image(
		cmd,
		img,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		mip_levels - 1,
		1,
	)

	end_single_time_commands(cmd)
}

create_texture_image :: proc() {
	img, err := png.load_from_bytes(TEXTURE_DATA, {.alpha_add_if_missing})
	if err != nil {
		log.panicf("Failed to decode texture: {}", err)
	}
	defer image.destroy(img)

	if img.depth != 8 || img.channels != 4 {
		log.panicf("Expected 8-bit RGBA texture, got depth {} channels {}", img.depth, img.channels)
	}

	width := u32(img.width)
	height := u32(img.height)
	pixels := img.pixels.buf[:]
	size := vk.DeviceSize(len(pixels))

	// full mip chain down to 1x1
	g.texture_mip_levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1

	staging_buffer, staging_memory := create_buffer(
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vk.FreeMemory(g.device, staging_memory, nil)
	defer vk.DestroyBuffer(g.device, staging_buffer, nil)

	mapped: rawptr
	vk_check(vk.MapMemory(g.device, staging_memory, 0, size, {}, &mapped))
	mem.copy(mapped, raw_data(pixels), int(size))
	vk.UnmapMemory(g.device, staging_memory)

	// TRANSFER_SRC is needed because mipmap generation blits from this image too
	g.texture_image, g.texture_memory = create_image(
		width,
		height,
		g.texture_mip_levels,
		TEXTURE_FORMAT,
		.OPTIMAL,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
	)

	// all levels at once: the copy below only fills level 0, mipmaps handle the rest
	cmd := begin_single_time_commands()
	transition_image(
		cmd,
		g.texture_image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{},
		{.TRANSFER_WRITE},
		0,
		g.texture_mip_levels,
	)
	end_single_time_commands(cmd)

	copy_buffer_to_image(staging_buffer, g.texture_image, width, height)

	// leaves every level in SHADER_READ_ONLY_OPTIMAL
	generate_mipmaps(
		g.texture_image,
		TEXTURE_FORMAT,
		i32(width),
		i32(height),
		g.texture_mip_levels,
	)

	log.infof("Texture: {}x{}, {} mip levels", width, height, g.texture_mip_levels)
}

create_texture_image_view :: proc() {
	view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = g.texture_image,
		viewType = .D2,
		format = TEXTURE_FORMAT,
		components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = g.texture_mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	vk_check(vk.CreateImageView(g.device, &view_ci, nil, &g.texture_view))
}

create_texture_sampler :: proc() {
	sampler_ci := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		mipmapMode              = .LINEAR,
		addressModeU            = .REPEAT,
		addressModeV            = .REPEAT,
		addressModeW            = .REPEAT,
		mipLodBias              = 0,
		anisotropyEnable        = b32(g.anisotropy_enabled),
		maxAnisotropy           = g.max_anisotropy,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		minLod                  = 0,
		maxLod                  = f32(g.texture_mip_levels),
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
	}
	vk_check(vk.CreateSampler(g.device, &sampler_ci, nil, &g.texture_sampler))

	if g.anisotropy_enabled {
		log.infof("Sampler: linear, repeat, {}x anisotropic", g.max_anisotropy)
	} else {
		log.info("Sampler: linear, repeat, anisotropy unsupported")
	}
}

destroy_texture :: proc() {
	vk.DestroySampler(g.device, g.texture_sampler, nil)
	vk.DestroyImageView(g.device, g.texture_view, nil)
	vk.DestroyImage(g.device, g.texture_image, nil)
	vk.FreeMemory(g.device, g.texture_memory, nil)
}
