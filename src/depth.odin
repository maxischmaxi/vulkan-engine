package main

import "core:log"
import vk "vendor:vulkan"

// Preferred first. D32_SFLOAT is required by the spec to support depth
// attachments, so the loop below always finds something on real hardware.
DEPTH_FORMAT_CANDIDATES := []vk.Format{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}

find_depth_format :: proc() -> vk.Format {
	for format in DEPTH_FORMAT_CANDIDATES {
		props: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(g.physical_device, format, &props)
		if .DEPTH_STENCIL_ATTACHMENT in props.optimalTilingFeatures {
			return format
		}
	}
	log.panic("No supported depth attachment format found")
}

depth_format_has_stencil :: proc(format: vk.Format) -> bool {
	return format == .D32_SFLOAT_S8_UINT || format == .D24_UNORM_S8_UINT
}

// The aspect mask must name every aspect the format actually has, otherwise
// the barrier below is rejected.
depth_aspect_mask :: proc(format: vk.Format) -> vk.ImageAspectFlags {
	return depth_format_has_stencil(format) ? {.DEPTH, .STENCIL} : {.DEPTH}
}

// Sized to match the swapchain, so this has to be rebuilt on every resize.
create_depth_resources :: proc() {
	g.depth_image, g.depth_memory = create_image(
		g.swapchain_extent.width,
		g.swapchain_extent.height,
		1,
		g.depth_format,
		.OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT},
		{.DEVICE_LOCAL},
	)

	// the view only ever covers depth, even when the format carries stencil too
	view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = g.depth_image,
		viewType = .D2,
		format = g.depth_format,
		components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
		subresourceRange = {
			aspectMask = {.DEPTH},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	vk_check(vk.CreateImageView(g.device, &view_ci, nil, &g.depth_view))
}

destroy_depth_resources :: proc() {
	vk.DestroyImageView(g.device, g.depth_view, nil)
	vk.DestroyImage(g.device, g.depth_image, nil)
	vk.FreeMemory(g.device, g.depth_memory, nil)
}

// Called once per frame. Coming from UNDEFINED is correct and cheaper than
// preserving the old contents, because loadOp CLEAR overwrites them anyway.
transition_depth_for_rendering :: proc(cmd: vk.CommandBuffer) {
	transition_image(
		cmd,
		g.depth_image,
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		0,
		1,
		depth_aspect_mask(g.depth_format),
	)
}
