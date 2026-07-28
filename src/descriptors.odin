package main

import "core:log"
import vk "vendor:vulkan"

// Descriptors are grouped by how often they change, which is the split every
// renderer ends up making:
//
//   set 0  per frame   FrameUniforms, point lights, shadow cascades
//   set 1  static      material table and the three texture arrays
//
// A pipeline declares only the sets it reads. The shadow pass wants nothing but
// the cascade matrices, and props want nothing textured at all, so putting
// everything in one set would force them to declare bindings they never touch.
//
// The HUD is the exception to the numbering: it reads nothing per frame and no
// material, so its glyph atlas is its own set 0. Binding the frame set to a pass
// that never looks at it is a lie about what the pipeline needs.
Descriptors :: struct {
	frame_layout:    vk.DescriptorSetLayout,
	material_layout: vk.DescriptorSetLayout,
	hud_layout:      vk.DescriptorSetLayout,
	pool:            vk.DescriptorPool,
	frame_sets:      [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	material_set:    vk.DescriptorSet,
	hud_set:         vk.DescriptorSet,
}

descriptors: Descriptors

// Layouts only describe shapes, so they can exist before any of the resources
// they will eventually point at. Pipelines need them, sets need the resources.
create_descriptor_layouts :: proc() {
	frame_bindings := []vk.DescriptorSetLayoutBinding {
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
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		// per-tile light masks, rewritten by the CPU every frame
		{
			binding = 3,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}

	material_bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 2,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 3,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}

	hud_bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}

	frame_ci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(frame_bindings)),
		pBindings    = raw_data(frame_bindings),
	}
	vk_check(vk.CreateDescriptorSetLayout(g.device, &frame_ci, nil, &descriptors.frame_layout))

	material_ci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(material_bindings)),
		pBindings    = raw_data(material_bindings),
	}
	vk_check(
		vk.CreateDescriptorSetLayout(g.device, &material_ci, nil, &descriptors.material_layout),
	)

	hud_ci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(hud_bindings)),
		pBindings    = raw_data(hud_bindings),
	}
	vk_check(vk.CreateDescriptorSetLayout(g.device, &hud_ci, nil, &descriptors.hud_layout))
}

create_descriptor_pool :: proc() {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
		// per-frame lights and tile masks, plus the one material table
		{type = .STORAGE_BUFFER, descriptorCount = 2 * MAX_FRAMES_IN_FLIGHT + 1},
		// per-frame shadow array, the three texture arrays, the glyph atlas
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT + 4},
	}

	pool_ci := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		// the per-frame sets, plus material and HUD
		maxSets       = MAX_FRAMES_IN_FLIGHT + 2,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}
	vk_check(vk.CreateDescriptorPool(g.device, &pool_ci, nil, &descriptors.pool))
}

// Every resource the sets point at has to exist by the time this runs.
create_descriptor_sets :: proc() {
	layouts: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		layouts[i] = descriptors.frame_layout
	}

	frame_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = descriptors.pool,
		descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
		pSetLayouts        = raw_data(&layouts),
	}
	// sets are freed with the pool, so there is no matching destroy call
	vk_check(vk.AllocateDescriptorSets(g.device, &frame_alloc, raw_data(&descriptors.frame_sets)))

	material_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = descriptors.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &descriptors.material_layout,
	}
	vk_check(vk.AllocateDescriptorSets(g.device, &material_alloc, &descriptors.material_set))

	hud_alloc := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = descriptors.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &descriptors.hud_layout,
	}
	vk_check(vk.AllocateDescriptorSets(g.device, &hud_alloc, &descriptors.hud_set))

	write_frame_sets()
	write_material_set()
	write_hud_set()

	log.info("Descriptors: set 0 per frame, set 1 static materials, HUD glyph atlas")
}

// Not file-private: rebuild_renderer calls it, because a new shadow image means
// the descriptors pointing at the old one are stale.
write_frame_sets :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		uniform_info := vk.DescriptorBufferInfo {
			buffer = frame_data.uniform_buffers[i],
			range  = size_of(Frame_Uniforms),
		}
		light_info := vk.DescriptorBufferInfo {
			buffer = frame_data.light_buffers[i],
			range  = MAX_POINT_LIGHTS * size_of(Point_Light),
		}
		shadow_info := vk.DescriptorImageInfo {
			sampler     = shadow.sampler,
			imageView   = shadow.array_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		tiles_info := vk.DescriptorBufferInfo {
			buffer = light_tiles.buffers[i],
			range  = LIGHT_TILES_BYTES,
		}

		writes := []vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = descriptors.frame_sets[i],
				dstBinding = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &uniform_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = descriptors.frame_sets[i],
				dstBinding = 1,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &light_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = descriptors.frame_sets[i],
				dstBinding = 2,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &shadow_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = descriptors.frame_sets[i],
				dstBinding = 3,
				descriptorCount = 1,
				descriptorType = .STORAGE_BUFFER,
				pBufferInfo = &tiles_info,
			},
		}
		vk.UpdateDescriptorSets(g.device, u32(len(writes)), raw_data(writes), 0, nil)
	}
}

// Not file-private: rebuild_samplers calls it, because a new sampler object
// means the set that names it has to be rewritten.
write_material_set :: proc() {
	material_info := vk.DescriptorBufferInfo {
		buffer = material_system.buffer,
		range  = vk.DeviceSize(len(MATERIALS) * size_of(Material)),
	}

	texture_infos: [3]vk.DescriptorImageInfo
	arrays := []Texture_Array{material_system.albedo, material_system.normal, material_system.orm}
	for arr, j in arrays {
		texture_infos[j] = {
			sampler     = material_system.sampler,
			imageView   = arr.view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
	}

	writes := []vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptors.material_set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &material_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptors.material_set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &texture_infos[0],
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptors.material_set,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &texture_infos[1],
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptors.material_set,
			dstBinding = 3,
			descriptorCount = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &texture_infos[2],
		},
	}
	vk.UpdateDescriptorSets(g.device, u32(len(writes)), raw_data(writes), 0, nil)
}

@(private = "file")
write_hud_set :: proc() {
	atlas_info := vk.DescriptorImageInfo {
		sampler     = hud_font.sampler,
		imageView   = hud_font.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = descriptors.hud_set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		pImageInfo      = &atlas_info,
	}
	vk.UpdateDescriptorSets(g.device, 1, &write, 0, nil)
}

destroy_descriptors :: proc() {
	vk.DestroyDescriptorPool(g.device, descriptors.pool, nil)
	vk.DestroyDescriptorSetLayout(g.device, descriptors.hud_layout, nil)
	vk.DestroyDescriptorSetLayout(g.device, descriptors.material_layout, nil)
	vk.DestroyDescriptorSetLayout(g.device, descriptors.frame_layout, nil)
}

// Set 0 for this frame. Every pass starts with this.
bind_frame_set :: proc(cmd: vk.CommandBuffer, layout: vk.PipelineLayout, frame: u32) {
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, layout, 0, 1, &descriptors.frame_sets[frame], 0, nil)
}

bind_material_set :: proc(cmd: vk.CommandBuffer, layout: vk.PipelineLayout) {
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, layout, 1, 1, &descriptors.material_set, 0, nil)
}

// Set 0 of the HUD pipeline, which declares no others.
bind_hud_set :: proc(cmd: vk.CommandBuffer, layout: vk.PipelineLayout) {
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, layout, 0, 1, &descriptors.hud_set, 0, nil)
}
