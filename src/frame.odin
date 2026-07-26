package main

import "core:math"
import "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"

// std140 layout. Everything is a mat4 or a vec4 so that no member needs manual
// padding -- std140 rounds scalars and vec3s up to 16 bytes anyway, and packing
// four floats into one vec4 by hand is cheaper than fighting the rules.
Frame_Uniforms :: struct {
	view:           linalg.Matrix4f32,
	proj:           linalg.Matrix4f32,
	view_proj:      linalg.Matrix4f32,
	cascade_vp:     [SHADOW_CASCADES]linalg.Matrix4f32,
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

// Odin's linalg targets OpenGL clip space (z from -1 to 1). Vulkan expects
// z from 0 to 1 and y pointing down, so the near half would be clipped away
// and depth precision halved. This builds the Vulkan convention directly.
perspective_vulkan :: proc(fovy, aspect, near, far: f32) -> linalg.Matrix4f32 {
	tan_half := math.tan(fovy * 0.5)

	m: linalg.Matrix4f32
	m[0, 0] = 1 / (aspect * tan_half)
	m[1, 1] = -1 / tan_half // negative because Vulkan's y axis points down
	m[2, 2] = far / (near - far)
	m[2, 3] = (far * near) / (near - far)
	m[3, 2] = -1
	return m
}

// one buffer per frame in flight: the GPU may still read frame N while we write N+1
create_uniform_buffers :: proc() {
	size := vk.DeviceSize(size_of(Frame_Uniforms))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		g.uniform_buffers[i], g.uniform_memories[i] = create_buffer(
			size,
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		// kept mapped for the whole run -- this changes every frame
		vk_check(vk.MapMemory(g.device, g.uniform_memories[i], 0, size, {}, &g.uniform_mapped[i]))
	}
}

destroy_uniform_buffers :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, g.uniform_memories[i])
		destroy_buffer(g.uniform_buffers[i], g.uniform_memories[i])
	}
}

create_descriptor_set_layout :: proc() {
	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .UNIFORM_BUFFER,
			descriptorCount = 1,
			stageFlags = {.VERTEX, .FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 2,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 3,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 4,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 5,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 6,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}

	layout_ci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
	}
	vk_check(vk.CreateDescriptorSetLayout(g.device, &layout_ci, nil, &g.descriptor_set_layout))
}

create_descriptor_pool :: proc() {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
		{type = .STORAGE_BUFFER, descriptorCount = 2 * MAX_FRAMES_IN_FLIGHT},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 4 * MAX_FRAMES_IN_FLIGHT},
	}

	pool_ci := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = MAX_FRAMES_IN_FLIGHT,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}
	vk_check(vk.CreateDescriptorPool(g.device, &pool_ci, nil, &g.descriptor_pool))
}

create_descriptor_sets :: proc() {
	layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		layouts[i] = g.descriptor_set_layout
	}

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = g.descriptor_pool,
		descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
		pSetLayouts        = raw_data(&layouts),
	}
	// sets are freed with the pool, so there is no matching destroy call
	vk_check(vk.AllocateDescriptorSets(g.device, &alloc_info, raw_data(&g.descriptor_sets)))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		uniform_info := vk.DescriptorBufferInfo {
			buffer = g.uniform_buffers[i],
			range  = size_of(Frame_Uniforms),
		}
		light_info := vk.DescriptorBufferInfo {
			buffer = g.light_buffers[i],
			range  = MAX_POINT_LIGHTS * size_of(Point_Light),
		}
		// materials never change, so all frames point at the same buffer
		material_info := vk.DescriptorBufferInfo {
			buffer = g.material_buffer,
			range  = vk.DeviceSize(len(MATERIALS) * size_of(Material)),
		}

		texture_infos := [3]vk.DescriptorImageInfo{}
		for arr, j in ([]Texture_Array{g.albedo_array, g.normal_array, g.orm_array}) {
			texture_infos[j] = {
				sampler     = g.texture_sampler,
				imageView   = arr.view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			}
		}

		shadow_info := vk.DescriptorImageInfo {
			sampler     = g.shadow.sampler,
			imageView   = g.shadow.array_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}

		writes := []vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &uniform_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 1,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &light_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 2,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &material_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 3,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &texture_infos[0],
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 4,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &texture_infos[1],
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 5,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &texture_infos[2],
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 6,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &shadow_info,
			},
		}
		vk.UpdateDescriptorSets(g.device, u32(len(writes)), raw_data(writes), 0, nil)
	}
}

update_uniform_buffer :: proc(frame: u32) {
	view := camera_view()
	proj := camera_projection()

	sun_dir := sun_direction_normalized()

	ubo := Frame_Uniforms {
		view = view,
		proj = proj,
		view_proj = proj * view,
		cascade_splits = {
			g.shadow.split_depths[0],
			g.shadow.split_depths[1],
			g.shadow.split_depths[2],
			0,
		},
		cascade_texel = {
			g.shadow.texel_world[0],
			g.shadow.texel_world[1],
			g.shadow.texel_world[2],
			0,
		},
		camera_pos = {camera.position.x, camera.position.y, camera.position.z, 1},
		sun_direction = {sun_dir.x, sun_dir.y, sun_dir.z, 0},
		sun_color = {
			sun.color.r * sun.intensity,
			sun.color.g * sun.intensity,
			sun.color.b * sun.intensity,
			0,
		},
		ambient_sky = {
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
		params = {exposure, f32(len(point_lights)), f32(debug_mode), 1.0 / SHADOW_RESOLUTION},
	}

	ubo.cascade_vp = g.shadow.cascade_vp

	mem.copy(g.uniform_mapped[frame], &ubo, size_of(ubo))
}
