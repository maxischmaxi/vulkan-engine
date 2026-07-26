package main

import "core:log"
import vk "vendor:vulkan"

// The frame, start to finish. Adding a pass means adding one line to
// record_main_pass and a module that owns its own state -- nothing here needs to
// know what that module does.

SKY_COLOR :: [4]f32{0.42, 0.55, 0.75, 1.0}

// Everything the simulation produced, handed to the GPU. Called once per frame
// after the tick loop, before recording.
build_frame :: proc(alpha: f32) {
	prop_begin_frame()
	submit_bots(alpha)
	submit_viewmodel()
	build_hud()
}

record_frame :: proc(cmd: vk.CommandBuffer, image_index, frame: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	// Fills the cascades and leaves them in SHADER_READ_ONLY. There is one
	// shadow image shared by both frames in flight, so its barrier also
	// serialises this pass against the previous frame's sampling -- cheap enough
	// here, and the alternative is another 100 MB of VRAM.
	record_shadow_pass(cmd, frame)

	transition_image(
		cmd,
		g.swapchain_images[image_index],
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{.TOP_OF_PIPE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{},
		{.COLOR_ATTACHMENT_WRITE},
	)
	transition_color_for_rendering(cmd)
	transition_depth_for_rendering(cmd)

	record_main_pass(cmd, image_index, frame)

	transition_image(
		cmd,
		g.swapchain_images[image_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BOTTOM_OF_PIPE},
		{.COLOR_ATTACHMENT_WRITE},
		{},
	)

	vk_check(vk.EndCommandBuffer(cmd))
}

@(private = "file")
record_main_pass :: proc(cmd: vk.CommandBuffer, image_index, frame: u32) {
	// With MSAA the pass renders into the multisampled image and the hardware
	// resolves into the swapchain on the way out, so the multisampled contents
	// themselves never need storing.
	color_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = msaa_enabled() ? g.color_view : g.swapchain_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = msaa_enabled() ? .DONT_CARE : .STORE,
		clearValue = {color = {float32 = SKY_COLOR}},
	}
	if msaa_enabled() {
		color_attachment.resolveMode = {.AVERAGE}
		color_attachment.resolveImageView = g.swapchain_views[image_index]
		color_attachment.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
	}

	// DONT_CARE on store: nothing reads the depth values after the frame
	depth_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = g.depth_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 1.0, stencil = 0}},
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = g.swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
		pDepthAttachment = &depth_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	viewport := vk.Viewport {
		width    = f32(g.swapchain_extent.width),
		height   = f32(g.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		extent = g.swapchain_extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	// Order matters: opaque geometry first so depth is complete, then blended
	// decals against it, then the weapon on a cleared depth buffer, then the HUD
	// on top of everything.
	record_world_pass(cmd, frame)
	record_prop_pass(cmd, frame)
	record_decal_pass(cmd, frame)
	record_viewmodel_pass(cmd, frame)
	record_hud_pass(cmd, frame)

	vk.CmdEndRendering(cmd)
}

draw_frame :: proc() {
	// Before the fence, so the rebuild's DeviceWaitIdle is the only thing this
	// frame waits on and no fence is left half-consumed.
	if g.framebuffer_resized {
		recreate_swapchain()
		return
	}

	frame := g.current_frame

	vk_check(vk.WaitForFences(g.device, 1, &g.in_flight_fences[frame], true, max(u64)))

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		g.device,
		g.swapchain,
		max(u64),
		g.image_available_semaphores[frame],
		{},
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		recreate_swapchain()
		return
	} else if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		log.panicf("Failed to acquire swapchain image: {}", acquire_result)
	}

	// only reset once we know we will submit, otherwise the fence stays unsignaled
	vk_check(vk.ResetFences(g.device, 1, &g.in_flight_fences[frame]))

	// safe to overwrite: the fence above guarantees this frame's buffers are free
	update_frame_uniforms(frame)
	update_light_buffer(frame)
	upload_prop_instances(frame)
	upload_decals(frame)
	upload_hud_quads(frame)

	cmd := g.command_buffers[frame]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	record_frame(cmd, image_index, frame)

	wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = g.image_available_semaphores[frame],
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}
	signal_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = g.render_finished_semaphores[image_index],
		stageMask = {.ALL_COMMANDS},
	}
	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}

	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_info,
	}
	vk_check(vk.QueueSubmit2(g.graphics_queue, 1, &submit_info, g.in_flight_fences[frame]))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &g.render_finished_semaphores[image_index],
		swapchainCount     = 1,
		pSwapchains        = &g.swapchain,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(g.present_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
		recreate_swapchain()
	} else if present_result != .SUCCESS {
		log.panicf("Failed to present: {}", present_result)
	}

	g.current_frame = (g.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
}
