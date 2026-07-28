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
	model_begin_frame()
	// The world stays up behind the menu; the actors in it do not. Networked
	// play draws the server's entities; the benchmark draws its local bots.
	if scene_playing() {
		if bench_active() {
			submit_bots(alpha)
		} else {
			submit_remote_entities()
		}
		submit_viewmodel()
	}
	build_hud()
}

record_frame :: proc(cmd: vk.CommandBuffer, image_index, frame: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	// Before anything opens a rendering block: resetting a query pool inside one
	// is illegal.
	gpu_timer_begin(cmd, frame)

	// Fills the cascades and leaves them in SHADER_READ_ONLY. There is one
	// shadow image shared by both frames in flight, so its barrier also
	// serialises this pass against the previous frame's sampling.
	//
	// Double-buffering the image to remove that wait has been tried and
	// measured: on the RADV iGPU the shadow raster then overlaps the previous
	// frame's fragment-bound world pass, the two fight over bandwidth, and the
	// frame gets 10 % slower (14.4 -> 15.7 ms at High); on a discrete GPU it
	// changes nothing. The serialisation stays because it wins.
	record_shadow_pass(cmd, frame)
	gpu_timer_mark(cmd, frame, .Shadow)

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

	record_scene_pass(cmd, image_index, frame)

	// At less than full scale the scene has landed in its own image and has to
	// be stretched onto the swapchain before the HUD is drawn over it.
	if scene_scaled() {
		blit_scene_to_swapchain(cmd, image_index)
	}

	record_hud_block(cmd, image_index, frame)

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

// Everything with a depth buffer, at whatever size the render scale asked for.
@(private = "file")
record_scene_pass :: proc(cmd: vk.CommandBuffer, image_index, frame: u32) {
	extent := scene_extent()

	// Three possible destinations, in order of preference: the multisampled
	// image when MSAA is on, the scene image when the scene is smaller than the
	// window, and the swapchain image when it is neither.
	target := scene_scaled() ? g.scene_view : g.swapchain_views[image_index]

	// With MSAA the pass renders into the multisampled image and the hardware
	// resolves into the target on the way out, so the multisampled contents
	// themselves never need storing.
	color_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = msaa_enabled() ? g.color_view : target,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = msaa_enabled() ? .DONT_CARE : .STORE,
		clearValue = {color = {float32 = SKY_COLOR}},
	}
	if msaa_enabled() {
		color_attachment.resolveMode = {.AVERAGE}
		color_attachment.resolveImageView = target
		color_attachment.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
	}

	// DONT_CARE on store: nothing reads the depth values after the frame.
	// Cleared to 0, which is the far plane under reversed-Z.
	depth_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = g.depth_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 0.0, stencil = 0}},
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
		pDepthAttachment = &depth_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)
	set_full_viewport(cmd, extent)

	// The overdraw view replaces the whole scene: the heatmap is only readable
	// when nothing opaque draws over it. The timer marks still run so the
	// query indices stay in step.
	if debug_mode == .Overdraw {
		record_world_overdraw(cmd, frame)
		gpu_timer_mark(cmd, frame, .World)
		gpu_timer_mark(cmd, frame, .Props)
		gpu_timer_mark(cmd, frame, .Decals)
		gpu_timer_mark(cmd, frame, .Viewmodel)
		vk.CmdEndRendering(cmd)
		return
	}

	// Order matters: opaque geometry first so depth is complete, then blended
	// decals against it, then the weapon on a cleared depth buffer.
	record_world_pass(cmd, frame)
	gpu_timer_mark(cmd, frame, .World)

	record_prop_pass(cmd, frame)
	record_model_pass(cmd, frame)
	gpu_timer_mark(cmd, frame, .Props)

	record_decal_pass(cmd, frame)
	gpu_timer_mark(cmd, frame, .Decals)

	record_viewmodel_block(cmd, frame)
	gpu_timer_mark(cmd, frame, .Viewmodel)

	vk.CmdEndRendering(cmd)
}

// The weapon, on a depth buffer of its own. Both halves of it draw here: the
// mesh the player sees, and whatever is still made of blocks -- currently the
// muzzle flash. One clear, then both, so they occlude each other correctly.
@(private = "file")
record_viewmodel_block :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if len(model_renderer.view_batches) == 0 && prop_view_instance_count() == 0 do return

	clear_viewmodel_depth(cmd)
	record_view_model_draws(cmd, frame)
	record_viewmodel_pass(cmd, frame)
}

// The HUD in its own block, at the window's own size. Text upscaled from a
// smaller render target turns to mush, which is exactly the thing a player would
// blame the render scale for -- so the scale never touches it.
@(private = "file")
record_hud_block :: proc(cmd: vk.CommandBuffer, image_index, frame: u32) {
	color_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = g.swapchain_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		// LOAD, not CLEAR: the scene is already in there
		loadOp      = .LOAD,
		storeOp     = .STORE,
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = g.swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)
	set_full_viewport(cmd, g.swapchain_extent)

	record_hud_pass(cmd, frame)
	gpu_timer_mark(cmd, frame, .Hud)

	vk.CmdEndRendering(cmd)
}

@(private = "file")
set_full_viewport :: proc(cmd: vk.CommandBuffer, extent: vk.Extent2D) {
	viewport := vk.Viewport {
		width    = f32(extent.width),
		height   = f32(extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		extent = extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

// A linear blit rather than a full-screen pass: no pipeline, no descriptor, no
// shader, and the hardware's own scaler. It is not a good upscaler, but the
// alternative costs a draw over every pixel of the window, which is most of what
// the render scale was trying to avoid.
@(private = "file")
blit_scene_to_swapchain :: proc(cmd: vk.CommandBuffer, image_index: u32) {
	transition_image(
		cmd,
		g.scene_image,
		.COLOR_ATTACHMENT_OPTIMAL,
		.TRANSFER_SRC_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BLIT},
		{.COLOR_ATTACHMENT_WRITE},
		{.TRANSFER_READ},
	)
	transition_image(
		cmd,
		g.swapchain_images[image_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.TRANSFER_DST_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.BLIT},
		{.COLOR_ATTACHMENT_WRITE},
		{.TRANSFER_WRITE},
	)

	scene := scene_extent()
	region := vk.ImageBlit2 {
		sType = .IMAGE_BLIT_2,
		srcSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		srcOffsets = {{}, {i32(scene.width), i32(scene.height), 1}},
		dstSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		dstOffsets = {{}, {i32(g.swapchain_extent.width), i32(g.swapchain_extent.height), 1}},
	}
	blit := vk.BlitImageInfo2 {
		sType          = .BLIT_IMAGE_INFO_2,
		srcImage       = g.scene_image,
		srcImageLayout = .TRANSFER_SRC_OPTIMAL,
		dstImage       = g.swapchain_images[image_index],
		dstImageLayout = .TRANSFER_DST_OPTIMAL,
		regionCount    = 1,
		pRegions       = &region,
		filter         = .LINEAR,
	}
	vk.CmdBlitImage2(cmd, &blit)

	// Back to a colour attachment, because the HUD is about to be drawn on it.
	transition_image(
		cmd,
		g.swapchain_images[image_index],
		.TRANSFER_DST_OPTIMAL,
		.COLOR_ATTACHMENT_OPTIMAL,
		{.BLIT},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER_WRITE},
		{.COLOR_ATTACHMENT_WRITE},
	)
}

draw_frame :: proc() {
	// Before the fence, so the rebuild's DeviceWaitIdle is the only thing this
	// frame waits on and no fence is left half-consumed.
	if g.framebuffer_resized {
		recreate_swapchain()
		return
	}

	frame := g.current_frame

	cpu_zone(.Wait_Fence)
	vk_check(vk.WaitForFences(g.device, 1, &g.in_flight_fences[frame], true, max(u64)))
	cpu_zone(.Other)

	// The fence above is what makes this slot's queries readable: it guarantees
	// the frame that wrote them has finished.
	gpu_timer_collect(frame)

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
	cpu_zone(.Upload)
	update_frame_uniforms(frame)
	update_light_buffer(frame)
	update_light_tiles(frame)
	upload_world_order(frame)
	upload_prop_instances(frame)
	upload_model_instances(frame)
	upload_decals(frame)
	upload_hud_quads(frame)

	cpu_zone(.Record)
	cmd := g.command_buffers[frame]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	record_frame(cmd, image_index, frame)

	cpu_zone(.Present)

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
	gpu_timer_submitted(frame)

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
