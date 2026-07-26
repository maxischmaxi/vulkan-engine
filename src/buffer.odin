package main

import "core:log"
import "core:mem"
import vk "vendor:vulkan"

// picks a memory type that the buffer accepts and that has all requested properties
find_memory_type :: proc(type_bits: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g.physical_device, &mem_props)

	for i in 0 ..< mem_props.memoryTypeCount {
		accepted := type_bits & (1 << i) != 0
		if accepted && properties <= mem_props.memoryTypes[i].propertyFlags {
			return i
		}
	}

	log.panicf("No memory type for bits {:b} with properties {}", type_bits, properties)
}

create_buffer :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
) {
	buffer_ci := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	vk_check(vk.CreateBuffer(g.device, &buffer_ci, nil, &buffer))

	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g.device, buffer, &requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = find_memory_type(requirements.memoryTypeBits, properties),
	}
	vk_check(vk.AllocateMemory(g.device, &alloc_info, nil, &memory))
	vk_check(vk.BindBufferMemory(g.device, buffer, memory, 0))

	return
}

destroy_buffer :: proc(buffer: vk.Buffer, memory: vk.DeviceMemory) {
	vk.DestroyBuffer(g.device, buffer, nil)
	vk.FreeMemory(g.device, memory, nil)
}

begin_single_time_commands :: proc() -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = g.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(g.device, &alloc_info, &cmd))

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))
	return cmd
}

// blocking submit -- only for setup work, never per frame
end_single_time_commands :: proc(cmd: vk.CommandBuffer) {
	cmd := cmd
	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit_info := vk.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmd_info,
	}
	vk_check(vk.QueueSubmit2(g.graphics_queue, 1, &submit_info, {}))
	vk_check(vk.QueueWaitIdle(g.graphics_queue))

	vk.FreeCommandBuffers(g.device, g.command_pool, 1, &cmd)
}

copy_buffer :: proc(src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd := begin_single_time_commands()
	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)
	end_single_time_commands(cmd)
}

// uploads via a staging buffer so the final buffer can live in device-local memory
create_device_local_buffer :: proc(
	data: []$T,
	usage: vk.BufferUsageFlags,
) -> (
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
) {
	size := vk.DeviceSize(len(data) * size_of(T))

	staging_buffer, staging_memory := create_buffer(
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	// memory must outlive the buffer that references it
	defer vk.FreeMemory(g.device, staging_memory, nil)
	defer vk.DestroyBuffer(g.device, staging_buffer, nil)

	mapped: rawptr
	vk_check(vk.MapMemory(g.device, staging_memory, 0, size, {}, &mapped))
	mem.copy(mapped, raw_data(data), int(size))
	vk.UnmapMemory(g.device, staging_memory)

	buffer, memory = create_buffer(size, usage | {.TRANSFER_DST}, {.DEVICE_LOCAL})
	copy_buffer(staging_buffer, buffer, size)

	return
}
