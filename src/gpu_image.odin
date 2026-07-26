package main

import "core:log"
import vk "vendor:vulkan"

create_image :: proc(
	width, height, mip_levels: u32,
	format: vk.Format,
	tiling: vk.ImageTiling,
	usage: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags,
	array_layers: u32 = 1,
	samples: vk.SampleCountFlags = {._1},
) -> (
	img: vk.Image,
	memory: vk.DeviceMemory,
) {
	image_ci := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = {width = width, height = height, depth = 1},
		mipLevels = mip_levels,
		arrayLayers = array_layers,
		samples = samples,
		tiling = tiling,
		usage = usage,
		sharingMode = .EXCLUSIVE,
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

transition_image :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
	base_mip: u32 = 0,
	mip_count: u32 = 1,
	aspect: vk.ImageAspectFlags = {.COLOR},
	base_layer: u32 = 0,
	layer_count: u32 = 1,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		image = image,
		subresourceRange = {
			aspectMask = aspect,
			baseMipLevel = base_mip,
			levelCount = mip_count,
			baseArrayLayer = base_layer,
			layerCount = layer_count,
		},
	}

	dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency_info)
}

// Uploads mip level 0 of one array layer from a tightly packed staging buffer.
copy_buffer_to_image :: proc(
	buffer: vk.Buffer,
	img: vk.Image,
	width, height: u32,
	layer: u32 = 0,
	buffer_offset: vk.DeviceSize = 0,
) {
	cmd := begin_single_time_commands()

	region := vk.BufferImageCopy {
		bufferOffset = buffer_offset,
		// zero means tightly packed, which is what the staging buffer holds
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = layer,
			layerCount = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {width, height, 1},
	}
	vk.CmdCopyBufferToImage(cmd, buffer, img, .TRANSFER_DST_OPTIMAL, 1, &region)

	end_single_time_commands(cmd)
}

// Halves the image repeatedly with linear blits. Every level walks
// TRANSFER_DST -> TRANSFER_SRC -> SHADER_READ_ONLY on its own. All array layers
// travel together in one blit per level, so the cost is one command per level
// regardless of how many materials the array holds.
generate_mipmaps :: proc(
	img: vk.Image,
	format: vk.Format,
	width, height: i32,
	mip_levels: u32,
	layer_count: u32 = 1,
) {
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
			{.COLOR},
			0,
			layer_count,
		)

		next_width := mip_width > 1 ? mip_width / 2 : 1
		next_height := mip_height > 1 ? mip_height / 2 : 1

		blit := vk.ImageBlit {
			srcSubresource = {
				aspectMask = {.COLOR},
				mipLevel = i - 1,
				baseArrayLayer = 0,
				layerCount = layer_count,
			},
			srcOffsets = {{0, 0, 0}, {mip_width, mip_height, 1}},
			dstSubresource = {
				aspectMask = {.COLOR},
				mipLevel = i,
				baseArrayLayer = 0,
				layerCount = layer_count,
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
			{.COLOR},
			0,
			layer_count,
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
		{.COLOR},
		0,
		layer_count,
	)

	end_single_time_commands(cmd)
}
