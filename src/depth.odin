package main

import "core:log"
import vk "vendor:vulkan"

// Preferred first. D32_SFLOAT is required by the spec to support depth
// attachments, so the loop below always finds something on real hardware.
DEPTH_FORMAT_CANDIDATES := []vk.Format{.D32_SFLOAT, .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT}

// Box geometry is nothing but hard edges, so anti-aliasing is what makes the
// result look like a game rather than a demo -- but it is also pure framebuffer
// bandwidth, and bandwidth is the thing a weak GPU has least of. Hence a
// setting, with this as the ceiling.
MAX_MSAA :: vk.SampleCountFlag._8

find_depth_format :: proc() -> vk.Format {
	for format in DEPTH_FORMAT_CANDIDATES {
		props: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(g.physical_device, format, &props)
		if .DEPTH_STENCIL_ATTACHMENT in props.optimalTilingFeatures {
			// Reversed-Z only pays off against a float exponent. On a normalised
			// integer format it is a harmless relabelling that buys nothing, so
			// say so rather than let the precision claim quietly become false.
			if format != .D32_SFLOAT && format != .D32_SFLOAT_S8_UINT {
				log.warnf("Depth format {} is not float -- reversed-Z gains nothing here", format)
			}
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
@(private = "file")
supported_msaa :: proc() -> vk.SampleCountFlags {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical_device, &props)
	return props.limits.framebufferColorSampleCounts & props.limits.framebufferDepthSampleCounts
}

// The highest count at or below what was asked for that the device can actually
// do. Rounding down rather than refusing means a config file naming an
// unsupported count still starts the game.
clamp_msaa :: proc(wanted: u8) -> u8 {
	supported := supported_msaa()

	for candidate in ([]vk.SampleCountFlag{._8, ._4, ._2}) {
		if candidate > MAX_MSAA do continue
		if u8(1) << u8(candidate) > wanted do continue
		if candidate in supported do return u8(1) << u8(candidate)
	}
	return 1
}

pick_msaa_samples :: proc() -> vk.SampleCountFlags {
	switch settings.msaa {
	case 8:
		return {._8}
	case 4:
		return {._4}
	case 2:
		return {._2}
	}
	return {._1}
}

msaa_enabled :: proc() -> bool {
	return g.msaa_samples != {._1}
}

// How large the scene itself is drawn. Everything fragment-side scales with
// this, which is what makes it the strongest dial there is; the HUD is drawn
// afterwards at the window's own size so text does not go through the stretch.
scene_extent :: proc() -> vk.Extent2D {
	scale := clamp(settings.render_scale, 0.5, 1.0)
	if scale >= 0.999 do return g.swapchain_extent

	return {
		width = max(u32(f32(g.swapchain_extent.width) * scale), 1),
		height = max(u32(f32(g.swapchain_extent.height) * scale), 1),
	}
}

scene_scaled :: proc() -> bool {
	return scene_extent() != g.swapchain_extent
}

// Both targets are sized to the scene, so they get rebuilt on every resize and
// on every change of render scale.
create_render_targets :: proc() {
	extent := scene_extent()

	// SAMPLED as well as attachment: the volumetric smoke marches rays against
	// the scene's own depth, so something has to be able to read it. Without
	// MSAA that is this image directly; with it, the resolve target below.
	depth_usage: vk.ImageUsageFlags = {.DEPTH_STENCIL_ATTACHMENT}
	if !msaa_enabled() do depth_usage += {.SAMPLED}

	g.depth_image, g.depth_memory = create_image(
		extent.width,
		extent.height,
		1,
		g.depth_format,
		.OPTIMAL,
		depth_usage,
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

	// Under MSAA the depth attachment is multisampled and cannot be sampled as
	// an ordinary texture, so the pass resolves it into this one on the way
	// out. SAMPLE_ZERO rather than an average: a depth buffer has no meaningful
	// mean, and one sample per pixel is all a ray needs to know where to stop.
	if msaa_enabled() {
		g.depth_resolve_image, g.depth_resolve_memory = create_image(
			extent.width,
			extent.height,
			1,
			g.depth_format,
			.OPTIMAL,
			{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
			{.DEVICE_LOCAL},
			1,
		)

		resolve_view_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = g.depth_resolve_image,
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
		vk_check(vk.CreateImageView(g.device, &resolve_view_ci, nil, &g.depth_resolve_view))
	}

	// At less than full scale the scene needs somewhere of its own to land
	// before being stretched onto the swapchain image.
	if scene_scaled() {
		g.scene_image, g.scene_memory = create_image(
			extent.width,
			extent.height,
			1,
			g.swapchain_format,
			.OPTIMAL,
			{.COLOR_ATTACHMENT, .TRANSFER_SRC},
			{.DEVICE_LOCAL},
			1,
		)

		scene_view_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = g.scene_image,
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
		vk_check(vk.CreateImageView(g.device, &scene_view_ci, nil, &g.scene_view))
	}

	// Without MSAA whatever the scene lands in is the colour target directly and
	// there is nothing to resolve from.
	if !msaa_enabled() do return

	g.color_image, g.color_memory = create_image(
		extent.width,
		extent.height,
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

// Driven by the handles rather than by re-deriving which targets ought to exist:
// a settings change rebuilds these while the old settings still describe them,
// and asking scene_scaled() here would free the wrong set.
destroy_render_targets :: proc() {
	vk.DestroyImageView(g.device, g.depth_view, nil)
	vk.DestroyImage(g.device, g.depth_image, nil)
	vk.FreeMemory(g.device, g.depth_memory, nil)
	g.depth_view, g.depth_image, g.depth_memory = {}, {}, {}

	if g.depth_resolve_image != 0 {
		vk.DestroyImageView(g.device, g.depth_resolve_view, nil)
		vk.DestroyImage(g.device, g.depth_resolve_image, nil)
		vk.FreeMemory(g.device, g.depth_resolve_memory, nil)
		g.depth_resolve_view, g.depth_resolve_image, g.depth_resolve_memory = {}, {}, {}
	}

	if g.scene_image != 0 {
		vk.DestroyImageView(g.device, g.scene_view, nil)
		vk.DestroyImage(g.device, g.scene_image, nil)
		vk.FreeMemory(g.device, g.scene_memory, nil)
		g.scene_view, g.scene_image, g.scene_memory = {}, {}, {}
	}

	if g.color_image != 0 {
		vk.DestroyImageView(g.device, g.color_view, nil)
		vk.DestroyImage(g.device, g.color_image, nil)
		vk.FreeMemory(g.device, g.color_memory, nil)
		g.color_view, g.color_image, g.color_memory = {}, {}, {}
	}
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

// The image the smoke pass samples: the resolve target under MSAA, the depth
// attachment itself without it.
depth_texture_view :: proc() -> vk.ImageView {
	return msaa_enabled() ? g.depth_resolve_view : g.depth_view
}

depth_texture_image :: proc() -> vk.Image {
	return msaa_enabled() ? g.depth_resolve_image : g.depth_image
}

transition_color_for_rendering :: proc(cmd: vk.CommandBuffer) {
	// Both come from UNDEFINED for the same reason the depth target does: the
	// pass clears or fully overwrites them, so preserving the old contents would
	// only cost bandwidth.
	if msaa_enabled() {
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

	if scene_scaled() {
		transition_image(
			cmd,
			g.scene_image,
			.UNDEFINED,
			.COLOR_ATTACHMENT_OPTIMAL,
			{.BLIT},
			{.COLOR_ATTACHMENT_OUTPUT},
			{},
			{.COLOR_ATTACHMENT_WRITE},
		)
	}
}
