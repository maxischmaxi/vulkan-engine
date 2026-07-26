package main

import "core:log"
import vk "vendor:vulkan"

// Preferred first. D32_SFLOAT is required by the spec to support depth
// attachments, so the loop below always finds something on real hardware.
DEPTH_FORMAT_CANDIDATES := []vk.Format{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}

// Box geometry is nothing but hard edges, so anti-aliasing is not optional if
// the result is meant to look like a game rather than a demo.
MAX_MSAA :: vk.SampleCountFlag._4

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

// Colour and depth must agree on the sample count, so only counts both support
// are usable.
pick_msaa_samples :: proc() -> vk.SampleCountFlags {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical_device, &props)

	supported :=
		props.limits.framebufferColorSampleCounts & props.limits.framebufferDepthSampleCounts

	for candidate in ([]vk.SampleCountFlag{._4, ._2}) {
		if candidate > MAX_MSAA do continue
		if candidate in supported do return {candidate}
	}
	return {._1}
}

msaa_enabled :: proc() -> bool {
	return g.msaa_samples != {._1}
}

// Both targets are sized to the swapchain, so they get rebuilt on every resize.
create_render_targets :: proc() {
	g.depth_image, g.depth_memory = create_image(
		g.swapchain_extent.width,
		g.swapchain_extent.height,
		1,
		g.depth_format,
		.OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT},
		{.DEVICE_LOCAL},
		1,
		g.msaa_samples,
	)

	// the view only ever covers depth, even when the format carries stencil too
	depth_view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = g.depth_image,
		viewType = .D2,
		format = g.depth_format,
		subresourceRange = {
			aspectMask = {.DEPTH},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	vk_check(vk.CreateImageView(g.device, &depth_view_ci, nil, &g.depth_view))

	// Without MSAA the swapchain image is the colour target and there is
	// nothing to resolve from.
	if !msaa_enabled() do return

	g.color_image, g.color_memory = create_image(
		g.swapchain_extent.width,
		g.swapchain_extent.height,
		1,
		g.swapchain_format,
		.OPTIMAL,
		{.COLOR_ATTACHMENT},
		{.DEVICE_LOCAL},
		1,
		g.msaa_samples,
	)

	color_view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = g.color_image,
		viewType = .D2,
		format = g.swapchain_format,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	vk_check(vk.CreateImageView(g.device, &color_view_ci, nil, &g.color_view))
}

destroy_render_targets :: proc() {
	vk.DestroyImageView(g.device, g.depth_view, nil)
	vk.DestroyImage(g.device, g.depth_image, nil)
	vk.FreeMemory(g.device, g.depth_memory, nil)

	if !msaa_enabled() do return

	vk.DestroyImageView(g.device, g.color_view, nil)
	vk.DestroyImage(g.device, g.color_image, nil)
	vk.FreeMemory(g.device, g.color_memory, nil)
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

transition_color_for_rendering :: proc(cmd: vk.CommandBuffer) {
	if !msaa_enabled() do return

	transition_image(
		cmd,
		g.color_image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{},
		{.COLOR_ATTACHMENT_WRITE},
	)
}
