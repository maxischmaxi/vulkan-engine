package main

import "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"

// std140 layout. Everything is a mat4 or a vec4 so that no member needs manual
// padding -- std140 rounds scalars and vec3s up to 16 bytes anyway, and packing
// four floats into one vec4 by hand is cheaper than fighting the rules.
//
// KEEP IN SYNC with shaders/include/frame.glsl. The asserts below catch changes
// on this side; nothing catches a change made only in the shader.
Frame_Uniforms :: struct {
	view:           linalg.Matrix4f32,
	// Kept separate from view_proj although nothing reads it yet: reconstructing
	// a view ray or a world position from depth needs the inverse of this one
	// alone, and that is what the first screen-space effect will want.
	proj:           linalg.Matrix4f32,
	view_proj:      linalg.Matrix4f32,
	cascade_vp:     [SHADOW_CASCADES_MAX]linalg.Matrix4f32,
	cascade_splits: [4]f32, // view-space distance where each cascade ends
	// world size of one shadow texel per cascade, which is what the normal
	// offset bias has to scale with -- a fixed offset is either useless in the
	// near cascade or visibly detaches shadows in the far one
	cascade_texel:  [4]f32,
	camera_pos:     [4]f32,
	sun_direction:  [4]f32, // xyz normalised, direction the light travels
	sun_color:      [4]f32, // rgb premultiplied by intensity
	ambient_sky:    [4]f32,
	ambient_ground: [4]f32,
	params:         [4]f32, // exposure, point light count, debug mode, shadow texel size
}

#assert(size_of(Frame_Uniforms) == 512)
#assert(offset_of(Frame_Uniforms, cascade_vp) == 192)
#assert(offset_of(Frame_Uniforms, cascade_splits) == 384)
#assert(offset_of(Frame_Uniforms, cascade_texel) == 400)
#assert(offset_of(Frame_Uniforms, params) == 496)

Debug_Mode :: enum i32 {
	None     = 0,
	Cascades = 1,
	Albedo   = 2,
	Normals  = 3,
	Lighting = 4, // lighting without albedo
}

debug_mode: Debug_Mode

// The per-frame GPU data behind descriptor set 0. One copy per frame in flight,
// because the GPU may still be reading frame N while we write N+1.
Frame_Data :: struct {
	uniform_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	uniform_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	uniform_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	light_buffers:    [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	light_memories:   [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	light_mapped:     [MAX_FRAMES_IN_FLIGHT]rawptr,
}

frame_data: Frame_Data

// Odin's linalg targets OpenGL clip space (z from -1 to 1). Vulkan expects
// z from 0 to 1 and y pointing down, so the near half would be clipped away
// and depth precision halved. This builds the Vulkan convention directly.
//
// Reversed-Z: the near plane maps to 1 and the far plane to 0, which is the two
// z rows below with near and far swapped and nothing else. A float depth buffer
// packs its mantissa near zero, and 1/z already packs precision near the eye, so
// the conventional mapping stacks both at the near plane and starves everything
// past a few metres. Swapping them makes the two cancel: at 100 m with the
// current 0.05/250 frustum the smallest resolvable step goes from ~12 mm to
// ~6 um. Everything that tests depth against this has to compare GREATER --
// see Depth_Test in pipeline_builder.
//
// The half angles come in as tangents rather than as a fov plus an aspect
// ratio, because that is the form the frustum corners are built from as well.
// One representation means the shadow cascades cannot drift out of step with
// what the camera actually sees.
perspective_tangents :: proc(half_w, half_h, near, far: f32) -> linalg.Matrix4f32 {
	m: linalg.Matrix4f32
	m[0, 0] = 1 / half_w
	m[1, 1] = -1 / half_h // negative because Vulkan's y axis points down
	m[2, 2] = near / (far - near)
	m[2, 3] = (near * far) / (far - near)
	m[3, 2] = -1
	return m
}

create_frame_data :: proc() {
	uniform_size := vk.DeviceSize(size_of(Frame_Uniforms))
	// sized for the maximum so lights can be added at runtime without
	// reallocating and rewriting descriptors
	light_size := vk.DeviceSize(MAX_POINT_LIGHTS * size_of(Point_Light))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		frame_data.uniform_buffers[i], frame_data.uniform_memories[i] = create_buffer(
			uniform_size,
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		// kept mapped for the whole run -- this changes every frame
		vk_check(
			vk.MapMemory(
				g.device,
				frame_data.uniform_memories[i],
				0,
				uniform_size,
				{},
				&frame_data.uniform_mapped[i],
			),
		)

		frame_data.light_buffers[i], frame_data.light_memories[i] = create_buffer(
			light_size,
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				frame_data.light_memories[i],
				0,
				light_size,
				{},
				&frame_data.light_mapped[i],
			),
		)
	}
}

destroy_frame_data :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, frame_data.light_memories[i])
		destroy_buffer(frame_data.light_buffers[i], frame_data.light_memories[i])

		vk.UnmapMemory(g.device, frame_data.uniform_memories[i])
		destroy_buffer(frame_data.uniform_buffers[i], frame_data.uniform_memories[i])
	}
}

update_frame_uniforms :: proc(frame: u32) {
	view := camera_view()
	proj := camera_projection()

	sun_dir := sun_direction_normalized()

	ubo := Frame_Uniforms {
		view           = view,
		proj           = proj,
		view_proj      = proj * view,
		cascade_vp     = shadow.cascade_vp,
		cascade_splits = {
			shadow.split_depths[0],
			shadow.split_depths[1],
			shadow.split_depths[2],
			0,
		},
		cascade_texel  = {shadow.texel_world[0], shadow.texel_world[1], shadow.texel_world[2], 0},
		camera_pos     = {camera.position.x, camera.position.y, camera.position.z, 1},
		sun_direction  = {sun_dir.x, sun_dir.y, sun_dir.z, 0},
		sun_color      = {
			sun.color.r * sun.intensity,
			sun.color.g * sun.intensity,
			sun.color.b * sun.intensity,
			0,
		},
		ambient_sky    = {
			ambient_sky.r * ambient_intensity,
			ambient_sky.g * ambient_intensity,
			ambient_sky.b * ambient_intensity,
			0,
		},
		ambient_ground = {
			ambient_ground.r * ambient_intensity,
			ambient_ground.g * ambient_intensity,
			ambient_ground.b * ambient_intensity,
			0,
		},
		params         = {
			exposure,
			f32(len(point_lights)),
			f32(debug_mode),
			1.0 / f32(shadow_resolution()),
		},
	}

	mem.copy(frame_data.uniform_mapped[frame], &ubo, size_of(ubo))
}

update_light_buffer :: proc(frame: u32) {
	if len(point_lights) == 0 do return
	dst := ([^]Point_Light)(frame_data.light_mapped[frame])
	copy(dst[:len(point_lights)], point_lights[:])
}
