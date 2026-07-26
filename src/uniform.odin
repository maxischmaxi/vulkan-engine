package main

import "core:math"
import "core:math/linalg"
import "core:mem"
import "vendor:glfw"
import vk "vendor:vulkan"

UniformBufferObject :: struct {
	view: linalg.Matrix4f32,
	proj: linalg.Matrix4f32,
}

PushConstants :: struct {
	model: linalg.Matrix4f32,
}

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

OBJECT_COUNT :: 2

CAMERA_EYE :: linalg.Vector3f32{0, -2.5, 2}

// per-object data, small enough to travel in the command buffer instead of a buffer
object_push_constants :: proc(index: int) -> PushConstants {
	elapsed := f32(glfw.GetTime())
	direction: f32 = index % 2 == 0 ? 1 : -1
	spin := elapsed * math.to_radians(f32(90)) * direction

	// Objects overlap on screen and sit at different depths. Index 0 is drawn
	// first but lies in front, so without a depth test index 1 would cover it.
	toward_camera := linalg.normalize(CAMERA_EYE)
	offset := linalg.Vector3f32{-0.3, 0, 0} + toward_camera * 0.6
	if index == 1 {
		offset = linalg.Vector3f32{0.3, 0, 0} - toward_camera * 0.6
	}

	return {
		model = linalg.matrix4_translate_f32(offset) *
		linalg.matrix4_rotate_f32(spin, {0, 0, 1}),
	}
}

// one buffer per frame in flight: the GPU may still read frame N while we write N+1
create_uniform_buffers :: proc() {
	size := vk.DeviceSize(size_of(UniformBufferObject))

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
			stageFlags = {.VERTEX},
		},
		{
			binding = 1,
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
	// one of each descriptor type per frame in flight
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
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
		buffer_info := vk.DescriptorBufferInfo {
			buffer = g.uniform_buffers[i],
			offset = 0,
			range  = size_of(UniformBufferObject),
		}

		// the texture is shared across frames, only the uniform buffer differs
		image_info := vk.DescriptorImageInfo {
			sampler     = g.texture_sampler,
			imageView   = g.texture_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}

		writes := []vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &buffer_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = g.descriptor_sets[i],
				dstBinding = 1,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &image_info,
			},
		}
		vk.UpdateDescriptorSets(g.device, u32(len(writes)), raw_data(writes), 0, nil)
	}
}

update_uniform_buffer :: proc(frame: u32) {
	aspect := f32(g.swapchain_extent.width) / f32(g.swapchain_extent.height)

	ubo := UniformBufferObject {
		// straight in front of the quad plane, so model +x stays screen-right
		view = linalg.matrix4_look_at_f32(CAMERA_EYE, {0, 0, 0}, {0, 0, 1}),
		proj = perspective_vulkan(math.to_radians(f32(45)), aspect, 0.1, 10),
	}

	mem.copy(g.uniform_mapped[frame], &ubo, size_of(ubo))
}

