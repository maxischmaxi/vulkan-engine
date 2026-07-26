package main

import "core:log"
import "core:math"
import "core:math/linalg"
import vk "vendor:vulkan"

SHADOW_CASCADES :: 3
SHADOW_RESOLUTION :: 2048
SHADOW_FORMAT :: vk.Format.D32_SFLOAT

// Beyond this the sun simply stops casting. Covering the whole 100 m map with
// three cascades would waste most of the resolution on geometry nobody looks at.
SHADOW_DISTANCE :: 90.0

// Weighting between a logarithmic and a linear split. Logarithmic alone puts
// almost everything in the first cascade; linear alone wastes the near one.
CASCADE_SPLIT_LAMBDA :: 0.85

Shadow_Map :: struct {
	image:        vk.Image,
	memory:       vk.DeviceMemory,
	array_view:   vk.ImageView, // for sampling all cascades
	layer_views:  [SHADOW_CASCADES]vk.ImageView, // one render target each
	sampler:      vk.Sampler,
	cascade_vp:   [SHADOW_CASCADES]linalg.Matrix4f32,
	split_depths: [SHADOW_CASCADES]f32, // view-space distance where each cascade ends
	texel_world:  [SHADOW_CASCADES]f32, // metres covered by one shadow texel
	world_pipe:   Pipeline, // baked map geometry
	prop_pipe:    Pipeline, // instanced boxes
}

shadow: Shadow_Map

// Right-handed orthographic projection into Vulkan clip space: z from 0 to 1
// and y flipped, matching perspective_vulkan so that rendering and sampling
// agree on which way is up.
ortho_vulkan :: proc(left, right, bottom, top, near, far: f32) -> linalg.Matrix4f32 {
	m: linalg.Matrix4f32
	m[0, 0] = 2 / (right - left)
	m[1, 1] = -2 / (top - bottom)
	m[2, 2] = -1 / (far - near)
	m[0, 3] = -(right + left) / (right - left)
	m[1, 3] = (top + bottom) / (top - bottom)
	m[2, 3] = -near / (far - near)
	m[3, 3] = 1
	return m
}

create_shadow_map :: proc() {
	shadow.image, shadow.memory = create_image(
		SHADOW_RESOLUTION,
		SHADOW_RESOLUTION,
		1,
		SHADOW_FORMAT,
		.OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
		{.DEVICE_LOCAL},
		SHADOW_CASCADES,
	)

	array_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = shadow.image,
		viewType = .D2_ARRAY,
		format = SHADOW_FORMAT,
		subresourceRange = {
			aspectMask = {.DEPTH},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = SHADOW_CASCADES,
		},
	}
	vk_check(vk.CreateImageView(g.device, &array_ci, nil, &shadow.array_view))

	// dynamic rendering targets a single layer at a time, so each needs its own view
	for i in 0 ..< SHADOW_CASCADES {
		layer_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = shadow.image,
			viewType = .D2,
			format = SHADOW_FORMAT,
			subresourceRange = {
				aspectMask = {.DEPTH},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = u32(i),
				layerCount = 1,
			},
		}
		vk_check(vk.CreateImageView(g.device, &layer_ci, nil, &shadow.layer_views[i]))
	}

	// A comparison sampler makes the hardware do the depth test and the bilinear
	// filter in one fetch, so a 3x3 kernel costs 9 taps but covers 4x4 texels.
	sampler_ci := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .LINEAR,
		minFilter     = .LINEAR,
		mipmapMode    = .NEAREST,
		addressModeU  = .CLAMP_TO_BORDER,
		addressModeV  = .CLAMP_TO_BORDER,
		addressModeW  = .CLAMP_TO_BORDER,
		// outside the cascade means fully lit, never a black band
		borderColor   = .FLOAT_OPAQUE_WHITE,
		compareEnable = true,
		compareOp     = .LESS_OR_EQUAL,
		minLod        = 0,
		maxLod        = 1,
	}
	vk_check(vk.CreateSampler(g.device, &sampler_ci, nil, &shadow.sampler))

	log.infof(
		"Shadows: {} cascades at {}x{}, {} m range",
		SHADOW_CASCADES,
		SHADOW_RESOLUTION,
		SHADOW_RESOLUTION,
		int(SHADOW_DISTANCE),
	)
}

// Two depth-only pipelines: one for the baked map, one for instanced boxes.
// Neither has a fragment shader, which halves the work per triangle compared to
// running an empty one.
//
// No culling. The orthographic light matrix flips y as well, so the winding
// would need its own reasoning -- and with a slope-scaled bias handling acne,
// culling buys nothing here but a way to get it wrong.
create_shadow_pipelines :: proc() {
	cascade_push := []vk.PushConstantRange {
		{stageFlags = {.VERTEX}, offset = 0, size = size_of(u32)},
	}

	world_bindings := []vk.VertexInputBindingDescription{vertex_binding_description()}
	world_attributes := position_attribute_description()

	shadow.world_pipe = build_pipeline(
		{
			name = "shadow/world",
			vert_spv = SHADOW_VERT_CODE,
			bindings = world_bindings,
			attributes = world_attributes[:],
			set_layouts = {descriptors.frame_layout},
			push_constants = cascade_push,
			depth_format = SHADOW_FORMAT,
			cull = .None,
			depth_bias = true,
		},
	)

	prop_bindings := prop_binding_descriptions()
	prop_attributes := prop_shadow_attribute_descriptions()

	shadow.prop_pipe = build_pipeline(
		{
			name = "shadow/props",
			vert_spv = SHADOW_PROP_VERT_CODE,
			bindings = prop_bindings[:],
			attributes = prop_attributes[:],
			set_layouts = {descriptors.frame_layout},
			push_constants = cascade_push,
			depth_format = SHADOW_FORMAT,
			cull = .None,
			depth_bias = true,
		},
	)
}

destroy_shadow_map :: proc() {
	destroy_pipeline(shadow.prop_pipe)
	destroy_pipeline(shadow.world_pipe)

	vk.DestroySampler(g.device, shadow.sampler, nil)
	for view in shadow.layer_views {
		vk.DestroyImageView(g.device, view, nil)
	}
	vk.DestroyImageView(g.device, shadow.array_view, nil)
	vk.DestroyImage(g.device, shadow.image, nil)
	vk.FreeMemory(g.device, shadow.memory, nil)
}

// Splits the view distance so each cascade covers a slice of the frustum. The
// blend of logarithmic and linear is the standard practical scheme.
cascade_split_distances :: proc() -> [SHADOW_CASCADES]f32 {
	near := camera.near
	far := f32(SHADOW_DISTANCE)
	ratio := far / near

	splits: [SHADOW_CASCADES]f32
	for i in 0 ..< SHADOW_CASCADES {
		p := f32(i + 1) / f32(SHADOW_CASCADES)
		log_split := near * math.pow(ratio, p)
		lin_split := near + (far - near) * p
		splits[i] = CASCADE_SPLIT_LAMBDA * log_split + (1 - CASCADE_SPLIT_LAMBDA) * lin_split
	}
	return splits
}

// Rebuilt every frame from the current view. Each cascade gets a light-space
// matrix that covers exactly its slice of the camera frustum.
update_cascades :: proc() {
	shadow.split_depths = cascade_split_distances()

	light_dir := sun_direction_normalized()

	// look_at degenerates when up is parallel to the view direction
	up := [3]f32{0, 0, 1}
	if abs(light_dir.z) > 0.99 {
		up = {0, 1, 0}
	}

	// Straight from the camera rather than recomputed here. Working it out a
	// second time is how a cascade ends up covering a frustum the camera no
	// longer has, and the shadows fall off the edge of the screen.
	half_w, half_h := camera_half_tangents(camera.fov_horizontal)

	forward := camera_forward()
	right := camera_right()
	cam_up := linalg.cross(right, forward)

	near_dist := camera.near
	for i in 0 ..< SHADOW_CASCADES {
		far_dist := shadow.split_depths[i]

		// eight corners of this slice of the frustum, in world space
		corners: [8][3]f32
		for j in 0 ..< 2 {
			d := j == 0 ? near_dist : far_dist
			center := camera.position + forward * d
			h := half_h * d
			w := half_w * d

			corners[j * 4 + 0] = center - right * w - cam_up * h
			corners[j * 4 + 1] = center + right * w - cam_up * h
			corners[j * 4 + 2] = center + right * w + cam_up * h
			corners[j * 4 + 3] = center - right * w + cam_up * h
		}

		// A bounding sphere rather than a box: its size does not change as the
		// camera turns, so the cascade covers a constant area and the shadow
		// edges stay put instead of shimmering.
		center: [3]f32
		for c in corners {
			center += c
		}
		center /= 8

		radius: f32
		for c in corners {
			radius = max(radius, linalg.length(c - center))
		}
		// round up so tiny numeric wobble in the radius cannot resize the cascade
		radius = math.ceil(radius * 16) / 16

		// Pull the light far enough back that nothing between it and the slice
		// gets clipped away and stops casting.
		extent := radius * 2
		depth_range := extent + 60
		eye := center - light_dir * (radius + 50)

		light_view := linalg.matrix4_look_at_f32(eye, center, up)
		light_proj := ortho_vulkan(-radius, radius, -radius, radius, 0, depth_range)
		vp := light_proj * light_view

		// Snap the projection to whole shadow texels. Without this the sampled
		// texel grid slides continuously as the player walks and every shadow
		// edge crawls.
		origin := vp * [4]f32{0, 0, 0, 1}
		scale := f32(SHADOW_RESOLUTION) / 2
		shadow_origin := [2]f32{origin.x, origin.y} * scale
		rounded := [2]f32{math.round(shadow_origin.x), math.round(shadow_origin.y)}
		offset := (rounded - shadow_origin) / scale

		vp[0, 3] += offset.x
		vp[1, 3] += offset.y

		shadow.cascade_vp[i] = vp
		shadow.texel_world[i] = extent / SHADOW_RESOLUTION
		near_dist = far_dist
	}
}

// Depth-only pass, one cascade per rendering block. Multiview could collapse
// these into a single pass, but at this triangle count the difference is noise
// and separate passes are far easier to inspect in a capture.
record_shadow_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	transition_image(
		cmd,
		shadow.image,
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.FRAGMENT_SHADER},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.SHADER_READ},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		0,
		1,
		{.DEPTH},
		0,
		SHADOW_CASCADES,
	)

	viewport := vk.Viewport {
		width    = SHADOW_RESOLUTION,
		height   = SHADOW_RESOLUTION,
		minDepth = 0,
		maxDepth = 1,
	}
	scissor := vk.Rect2D {
		extent = {SHADOW_RESOLUTION, SHADOW_RESOLUTION},
	}

	for i in 0 ..< SHADOW_CASCADES {
		depth_attachment := vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = shadow.layer_views[i],
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = {depthStencil = {depth = 1.0}},
		}

		rendering_info := vk.RenderingInfo {
			sType = .RENDERING_INFO,
			renderArea = {extent = {SHADOW_RESOLUTION, SHADOW_RESOLUTION}},
			layerCount = 1,
			pDepthAttachment = &depth_attachment,
		}

		vk.CmdBeginRendering(cmd, &rendering_info)
		vk.CmdSetViewport(cmd, 0, 1, &viewport)
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		// Constant bias lifts everything off the surface, slope bias adds more
		// where the surface is nearly edge-on to the light and one texel spans a
		// lot of depth.
		vk.CmdSetDepthBias(cmd, 1.5, 0, 3.0)

		cascade := u32(i)

		vk.CmdBindPipeline(cmd, .GRAPHICS, shadow.world_pipe.pipeline)
		vk.CmdPushConstants(cmd, shadow.world_pipe.layout, {.VERTEX}, 0, size_of(u32), &cascade)
		bind_frame_set(cmd, shadow.world_pipe.layout, frame)
		bind_world_geometry(cmd)
		vk.CmdDrawIndexed(cmd, world_renderer.index_count, 1, 0, 0, 0)

		if prop_world_instance_count() > 0 {
			vk.CmdBindPipeline(cmd, .GRAPHICS, shadow.prop_pipe.pipeline)
			vk.CmdPushConstants(cmd, shadow.prop_pipe.layout, {.VERTEX}, 0, size_of(u32), &cascade)
			bind_frame_set(cmd, shadow.prop_pipe.layout, frame)
			record_prop_shadow_draw(cmd, frame)
		}

		vk.CmdEndRendering(cmd)
	}

	transition_image(
		cmd,
		shadow.image,
		.DEPTH_ATTACHMENT_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.FRAGMENT_SHADER},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.SHADER_READ},
		0,
		1,
		{.DEPTH},
		0,
		SHADOW_CASCADES,
	)
}
