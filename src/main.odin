package main

import "base:runtime"
import "core:log"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

Globals :: struct {
	odin_context:               runtime.Context,
	window:                     glfw.WindowHandle,
	instance:                   vk.Instance,
	debug_messenger:            vk.DebugUtilsMessengerEXT,
	surface:                    vk.SurfaceKHR,
	physical_device:            vk.PhysicalDevice,
	device:                     vk.Device,
	graphics_family:            u32,
	present_family:             u32,
	graphics_queue:             vk.Queue,
	present_queue:              vk.Queue,
	swapchain:                  vk.SwapchainKHR,
	swapchain_images:           []vk.Image,
	swapchain_views:            []vk.ImageView,
	swapchain_format:           vk.Format,
	swapchain_extent:           vk.Extent2D,
	command_pool:               vk.CommandPool,
	command_buffers:            [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight_fences:           [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	render_finished_semaphores: []vk.Semaphore, // one per swapchain image
	current_frame:              u32,
	pipeline_layout:            vk.PipelineLayout,
	graphics_pipeline:          vk.Pipeline,
	shadow_layout:              vk.PipelineLayout,
	shadow_pipeline:            vk.Pipeline,

	// the entire static map: one vertex buffer, one index buffer, one draw
	world_vertex_buffer:        vk.Buffer,
	world_vertex_memory:        vk.DeviceMemory,
	world_index_buffer:         vk.Buffer,
	world_index_memory:         vk.DeviceMemory,
	world_index_count:          u32,
	material_buffer:            vk.Buffer,
	material_memory:            vk.DeviceMemory,
	descriptor_set_layout:      vk.DescriptorSetLayout,
	descriptor_pool:            vk.DescriptorPool,
	descriptor_sets:            [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	uniform_buffers:            [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	uniform_memories:           [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	uniform_mapped:             [MAX_FRAMES_IN_FLIGHT]rawptr,
	light_buffers:              [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	light_memories:             [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	light_mapped:               [MAX_FRAMES_IN_FLIGHT]rawptr,
	albedo_array:               Texture_Array,
	normal_array:               Texture_Array,
	orm_array:                  Texture_Array,
	texture_sampler:            vk.Sampler,
	texture_mip_levels:         u32,
	anisotropy_enabled:         bool,
	max_anisotropy:             f32,
	shadow:                     Shadow_Map,
	msaa_samples:               vk.SampleCountFlags,
	color_image:                vk.Image, // multisampled, resolved into the swapchain
	color_memory:               vk.DeviceMemory,
	color_view:                 vk.ImageView,
	depth_image:                vk.Image,
	depth_memory:               vk.DeviceMemory,
	depth_view:                 vk.ImageView,
	depth_format:               vk.Format,
	validation_enabled:         bool,
	last_time:                  f64,
	delta_time:                 f32,
}

g: Globals

QueueFamilies :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

main :: proc() {
	context.logger = log.create_console_logger()
	g.odin_context = context

	glfw.SetErrorCallback(proc "c" (error: i32, description: cstring) {
		context = g.odin_context
		log.errorf("GLFW Error {}: {}", error, description)
	})

	if !glfw.Init() do return
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	g.window = glfw.CreateWindow(1600, 900, "dust2", nil, nil)
	if g.window == nil do return
	defer glfw.DestroyWindow(g.window)

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	log.assert(vk.CreateInstance != nil, "Failed to load Vulkan API")

	create_instance()
	defer destroy_instance()

	create_surface()
	defer vk.DestroySurfaceKHR(g.instance, g.surface, nil)

	pick_physical_device()

	create_logical_device()
	defer vk.DestroyDevice(g.device, nil)

	// the pipelines bake both of these in, so they are picked before anything uses them
	g.depth_format = find_depth_format()
	g.msaa_samples = pick_msaa_samples()
	log.infof("Depth format: {}, MSAA: {}", g.depth_format, g.msaa_samples)

	create_swapchain()
	get_swapchain_images()
	create_image_views()
	defer destroy_swapchain()

	create_render_targets()
	defer destroy_render_targets()

	// the pool must exist before any buffer upload, which uses a one-off command buffer
	create_command_pool()
	defer vk.DestroyCommandPool(g.device, g.command_pool, nil)

	// --------------------------------------------------------------- scene
	brushes := build_dust2()
	defer delete(brushes)

	bake_world(brushes)
	create_world_buffers()
	defer destroy_world_buffers()

	create_material_buffer()
	defer destroy_material_buffer()

	create_texture_arrays()
	create_texture_sampler()
	defer destroy_texture_arrays()

	init_lights()
	create_light_buffer()
	defer destroy_light_buffer()

	create_shadow_map()
	defer destroy_shadow_map()

	// --------------------------------------------------------------- render
	create_uniform_buffers()
	defer destroy_uniform_buffers()

	// every resource the sets point at has to exist by now
	create_descriptor_set_layout()
	defer vk.DestroyDescriptorSetLayout(g.device, g.descriptor_set_layout, nil)

	create_descriptor_pool()
	defer vk.DestroyDescriptorPool(g.device, g.descriptor_pool, nil)

	create_descriptor_sets()

	create_graphics_pipeline()
	create_shadow_pipeline()
	defer destroy_graphics_pipeline()

	create_command_buffers()

	create_sync_objects()
	defer destroy_sync_objects()

	// ---------------------------------------------------------------- input
	init_camera()
	init_player(brushes)
	init_input()
	defer destroy_input()
	log_input_support()

	g.last_time = glfw.GetTime()

	for !glfw.WindowShouldClose(g.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()
		update(&g.delta_time)
		draw_frame()
	}

	vk_check(vk.DeviceWaitIdle(g.device))
}

// Everything that happens between two frames: timing, input, movement.
update :: proc(dt_out: ^f32) {
	now := glfw.GetTime()
	// A long stall (debugger, compositor hiccup) must not teleport the player
	// through a wall on the next step.
	dt := f32(min(now - g.last_time, 0.1))
	g.last_time = now
	dt_out^ = dt

	if key_pressed(glfw.KEY_ESCAPE) && input.cursor_grabbed {
		grab_cursor(false)
	}

	if input.cursor_grabbed {
		dx, dy := consume_mouse_delta()
		camera_apply_mouse(dx, dy)
		update_player(dt)
	}
	sync_camera_to_player()

	if key_pressed(glfw.KEY_F1) do set_debug_mode(.None)
	if key_pressed(glfw.KEY_F2) do set_debug_mode(.Cascades)
	if key_pressed(glfw.KEY_F3) do set_debug_mode(.Albedo)
	if key_pressed(glfw.KEY_F4) do set_debug_mode(.Normals)
	if key_pressed(glfw.KEY_F5) do set_debug_mode(.Lighting)

	update_cascades()
	log_frame_stats(dt)
}

set_debug_mode :: proc(mode: Debug_Mode) {
	debug_mode = mode
	log.infof("Debug view: {}", mode)
}

// One line a second, so the frame time is visible without a profiler.
log_frame_stats :: proc(dt: f32) {
	@(static) accum: f32
	@(static) frames: int

	accum += dt
	frames += 1
	if accum < 1 do return

	log.infof(
		"{:.1f} fps ({:.2f} ms)  pos {:.1f} {:.1f} {:.1f}{}",
		f32(frames) / accum,
		accum / f32(frames) * 1000,
		player.position.x,
		player.position.y,
		player.position.z,
		player.noclip ? "  [noclip]" : "",
	)
	accum = 0
	frames = 0
}

VALIDATION_LAYER :: "VK_LAYER_KHRONOS_validation"

is_layer_available :: proc(name: string) -> bool {
	count: u32
	vk.EnumerateInstanceLayerProperties(&count, nil)
	props := make([]vk.LayerProperties, count, context.temp_allocator)
	vk.EnumerateInstanceLayerProperties(&count, raw_data(props))

	for &p in props {
		if string(cstring(&p.layerName[0])) == name do return true
	}
	return false
}

is_instance_extension_available :: proc(name: string) -> bool {
	count: u32
	vk.EnumerateInstanceExtensionProperties(nil, &count, nil)
	props := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(props))

	for &p in props {
		if string(cstring(&p.extensionName[0])) == name do return true
	}
	return false
}

create_instance :: proc() {
	layers := make([dynamic]cstring, 0, 1, context.temp_allocator)
	extensions := slice.clone_to_dynamic(
		glfw.GetRequiredInstanceExtensions(),
		context.temp_allocator,
	)

	// Validation costs performance, so it is a debug-build feature. Even then the
	// layer package may not be installed, which used to abort with LAYER_NOT_PRESENT.
	when ODIN_DEBUG {
		layer_ok := is_layer_available(VALIDATION_LAYER)
		debug_utils_ok := is_instance_extension_available(vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		if layer_ok && debug_utils_ok {
			g.validation_enabled = true
			append(&layers, cstring(VALIDATION_LAYER))
			append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		} else if !layer_ok {
			log.warnf(
				"{} not installed, continuing without validation (Arch: pacman -S vulkan-validation-layers)",
				VALIDATION_LAYER,
			)
		} else {
			log.warnf("{} unavailable, continuing without validation", vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		}
	}

	debug_messenger_ci := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.VALIDATION, .PERFORMANCE},
		pfnUserCallback = proc "system" (
			messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
			messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
			pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
			pUserData: rawptr,
		) -> b32 {
			context = g.odin_context
			context.logger.options = {.Level, .Terminal_Color}
			level: log.Level
			if .ERROR in messageSeverity do level = .Error
			else if .WARNING in messageSeverity do level = .Warning
			else if .INFO in messageSeverity do level = .Info
			else do level = .Debug
			log.log(level, pCallbackData.pMessage)
			return false
		},
	}

	// only chained in when the messenger can actually be created, so that
	// instance creation itself is covered by validation
	next: rawptr
	if g.validation_enabled {
		next = &debug_messenger_ci
	}

	instance_ci := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &{sType = .APPLICATION_INFO, apiVersion = vk.API_VERSION_1_3},
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext                   = next,
	}

	vk_check(vk.CreateInstance(&instance_ci, nil, &g.instance))

	vk.load_proc_addresses_instance(g.instance)
	log.assert(vk.DestroyInstance != nil, "Failed to load Vulkan instance")

	if g.validation_enabled {
		vk_check(
			vk.CreateDebugUtilsMessengerEXT(
				g.instance,
				&debug_messenger_ci,
				nil,
				&g.debug_messenger,
			),
		)
		log.infof("Validation enabled via {}", VALIDATION_LAYER)
	}
}

vk_check :: proc(result: vk.Result, location := #caller_location) {
	if result != .SUCCESS do log.panicf("Vulkan Failure: {}", result, location = location)
}

destroy_instance :: proc() {
	if g.validation_enabled {
		vk.DestroyDebugUtilsMessengerEXT(g.instance, g.debug_messenger, nil)
	}
	vk.DestroyInstance(g.instance, nil)
}

create_surface :: proc() {
	vk_check(glfw.CreateWindowSurface(g.instance, g.window, nil, &g.surface))
}

find_queue_families :: proc(device: vk.PhysicalDevice) -> QueueFamilies {
	families: QueueFamilies

	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)
	props := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(props))

	for p, i in props {
		index := u32(i)

		if .GRAPHICS in p.queueFlags {
			families.graphics = index
		}

		present_support: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, index, g.surface, &present_support)
		if present_support {
			families.present = index
		}

		if families.graphics != nil && families.present != nil {
			break
		}
	}

	return families
}


has_swapchain_support :: proc(device: vk.PhysicalDevice) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	props := make([]vk.ExtensionProperties, count, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(props))

	for &p in props {
		name := string(cstring(&p.extensionName[0]))
		if name == vk.KHR_SWAPCHAIN_EXTENSION_NAME {
			return true
		}
	}
	return false
}

is_device_suitable :: proc(device: vk.PhysicalDevice) -> bool {
	families := find_queue_families(device)
	if families.graphics == nil || families.present == nil do return false
	if !has_swapchain_support(device) do return false

	// surface must offer at least one format and one present mode
	format_count, present_mode_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(device, g.surface, &format_count, nil)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(device, g.surface, &present_mode_count, nil)

	return format_count > 0 && present_mode_count > 0
}

pick_physical_device :: proc() {
	count: u32
	vk.EnumeratePhysicalDevices(g.instance, &count, nil)
	if count == 0 do log.panic("No Vulkan-capable GPU found")

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g.instance, &count, raw_data(devices))

	best_score := -1
	for device in devices {
		if !is_device_suitable(device) do continue

		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)

		score := 0
		if props.deviceType == .DISCRETE_GPU do score += 1000
		score += int(props.limits.maxImageDimension2D)

		if score > best_score {
			best_score = score
			g.physical_device = device
		}
	}

	if g.physical_device == nil do log.panic("No suitable GPU found")

	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(g.physical_device, &props)
	log.infof("Selected GPU: {}", string(cstring(&props.deviceName[0])))

	families := find_queue_families(g.physical_device)
	g.graphics_family = families.graphics.?
	g.present_family = families.present.?
}


create_logical_device :: proc() {
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		synchronization2 = true,
	}

	// anisotropic filtering is optional -- enable it only where the device offers it
	supported: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(g.physical_device, &supported)

	device_features: vk.PhysicalDeviceFeatures
	g.max_anisotropy = 1
	if supported.samplerAnisotropy {
		device_features.samplerAnisotropy = true
		g.anisotropy_enabled = true

		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(g.physical_device, &props)
		g.max_anisotropy = props.limits.maxSamplerAnisotropy
	}

	queue_priority := f32(1.0)

	queue_cis := make([dynamic]vk.DeviceQueueCreateInfo, 0, 2, context.temp_allocator)
	append(
		&queue_cis,
		vk.DeviceQueueCreateInfo {
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = g.graphics_family,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		},
	)

	// same family must not be requested twice
	if g.present_family != g.graphics_family {
		append(
			&queue_cis,
			vk.DeviceQueueCreateInfo {
				sType = .DEVICE_QUEUE_CREATE_INFO,
				queueFamilyIndex = g.present_family,
				queueCount = 1,
				pQueuePriorities = &queue_priority,
			},
		)
	}

	device_extensions := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

	device_ci := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features13,
		queueCreateInfoCount    = u32(len(queue_cis)),
		pQueueCreateInfos       = raw_data(queue_cis),
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pEnabledFeatures        = &device_features,
	}

	vk_check(vk.CreateDevice(g.physical_device, &device_ci, nil, &g.device))

	vk.load_proc_addresses_device(g.device)

	vk.GetDeviceQueue(g.device, g.graphics_family, 0, &g.graphics_queue)
	vk.GetDeviceQueue(g.device, g.present_family, 0, &g.present_queue)
}

choose_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for f in formats {
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR {
			return f
		}
	}
	// guaranteed to have at least one entry, so this is safe
	return formats[0]
}

choose_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for m in modes {
		if m == .MAILBOX do return m
	}
	// FIFO is the only mode guaranteed by the spec
	return .FIFO
}

choose_extent :: proc(caps: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	// a defined currentExtent means the surface size is fixed by the compositor
	if caps.currentExtent.width != max(u32) {
		return caps.currentExtent
	}

	width, height := glfw.GetFramebufferSize(g.window)
	return vk.Extent2D {
		width = clamp(u32(width), caps.minImageExtent.width, caps.maxImageExtent.width),
		height = clamp(u32(height), caps.minImageExtent.height, caps.maxImageExtent.height),
	}
}

create_swapchain :: proc() {
	caps: vk.SurfaceCapabilitiesKHR
	vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(g.physical_device, g.surface, &caps))

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(g.physical_device, g.surface, &format_count, nil)
	formats := make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		g.physical_device,
		g.surface,
		&format_count,
		raw_data(formats),
	)

	mode_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(g.physical_device, g.surface, &mode_count, nil)
	modes := make([]vk.PresentModeKHR, mode_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		g.physical_device,
		g.surface,
		&mode_count,
		raw_data(modes),
	)

	surface_format := choose_surface_format(formats)
	present_mode := choose_present_mode(modes)
	extent := choose_extent(caps)

	// one more than the minimum avoids waiting on the driver
	image_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 && image_count > caps.maxImageCount {
		image_count = caps.maxImageCount
	}

	swapchain_ci := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = g.surface,
		minImageCount    = image_count,
		imageFormat      = surface_format.format,
		imageColorSpace  = surface_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
		oldSwapchain     = {},
	}

	families := []u32{g.graphics_family, g.present_family}
	if g.graphics_family != g.present_family {
		swapchain_ci.imageSharingMode = .CONCURRENT
		swapchain_ci.queueFamilyIndexCount = 2
		swapchain_ci.pQueueFamilyIndices = raw_data(families)
	} else {
		swapchain_ci.imageSharingMode = .EXCLUSIVE
	}

	vk_check(vk.CreateSwapchainKHR(g.device, &swapchain_ci, nil, &g.swapchain))

	g.swapchain_format = surface_format.format
	g.swapchain_extent = extent

	log.infof(
		"Swapchain: {}x{}, {}, {}",
		extent.width,
		extent.height,
		surface_format.format,
		present_mode,
	)
}

get_swapchain_images :: proc() {
	count: u32
	vk_check(vk.GetSwapchainImagesKHR(g.device, g.swapchain, &count, nil))
	g.swapchain_images = make([]vk.Image, count)
	vk_check(vk.GetSwapchainImagesKHR(g.device, g.swapchain, &count, raw_data(g.swapchain_images)))

	log.infof("Swapchain image count: {}", count)
}

create_image_views :: proc() {
	g.swapchain_views = make([]vk.ImageView, len(g.swapchain_images))

	for image, i in g.swapchain_images {
		view_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = g.swapchain_format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		vk_check(vk.CreateImageView(g.device, &view_ci, nil, &g.swapchain_views[i]))
	}
}

destroy_swapchain :: proc() {
	for view in g.swapchain_views {
		vk.DestroyImageView(g.device, view, nil)
	}
	delete(g.swapchain_views)
	delete(g.swapchain_images)
	vk.DestroySwapchainKHR(g.device, g.swapchain, nil)
}

create_command_pool :: proc() {
	pool_ci := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = g.graphics_family,
	}
	vk_check(vk.CreateCommandPool(g.device, &pool_ci, nil, &g.command_pool))
}

create_command_buffers :: proc() {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = g.command_pool,
		level              = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}
	vk_check(vk.AllocateCommandBuffers(g.device, &alloc_info, raw_data(&g.command_buffers)))
}

create_sync_objects :: proc() {
	semaphore_ci := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	// signaled, otherwise the very first frame would wait forever
	fence_ci := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_check(
			vk.CreateSemaphore(g.device, &semaphore_ci, nil, &g.image_available_semaphores[i]),
		)
		vk_check(vk.CreateFence(g.device, &fence_ci, nil, &g.in_flight_fences[i]))
	}

	// one per swapchain image, not per frame in flight -- see below
	g.render_finished_semaphores = make([]vk.Semaphore, len(g.swapchain_images))
	for i in 0 ..< len(g.swapchain_images) {
		vk_check(
			vk.CreateSemaphore(g.device, &semaphore_ci, nil, &g.render_finished_semaphores[i]),
		)
	}
}

record_command_buffer :: proc(cmd: vk.CommandBuffer, image_index: u32, frame: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	// Fills the cascades and leaves them in SHADER_READ_ONLY. There is one
	// shadow image shared by both frames in flight, so its barrier also
	// serialises this pass against the previous frame's sampling -- cheap
	// enough here, and the alternative is another 100 MB of VRAM.
	record_shadow_pass(cmd)

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

	// With MSAA the pass renders into the multisampled image and the hardware
	// resolves into the swapchain on the way out, so the multisampled contents
	// themselves never need storing.
	color_attachment := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = msaa_enabled() ? g.color_view : g.swapchain_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = msaa_enabled() ? .DONT_CARE : .STORE,
		clearValue = {color = {float32 = {0.42, 0.55, 0.75, 1.0}}}, // sky
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

	vk.CmdBindPipeline(cmd, .GRAPHICS, g.graphics_pipeline)

	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(g.swapchain_extent.width),
		height   = f32(g.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = g.swapchain_extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &g.world_vertex_buffer, raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, g.world_index_buffer, 0, .UINT32)

	vk.CmdBindDescriptorSets(
		cmd,
		.GRAPHICS,
		g.pipeline_layout,
		0,
		1,
		&g.descriptor_sets[frame],
		0,
		nil,
	)

	// the entire map in one call -- world-space baked geometry needs no per-object state
	vk.CmdDrawIndexed(cmd, g.world_index_count, 1, 0, 0, 0)

	vk.CmdEndRendering(cmd)

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

draw_frame :: proc() {
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
	update_uniform_buffer(frame)
	update_light_buffer(frame)

	cmd := g.command_buffers[frame]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	record_command_buffer(cmd, image_index, frame)

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

recreate_swapchain :: proc() {
	// wait out minimization: a zero-sized framebuffer cannot back a swapchain
	for {
		width, height := glfw.GetFramebufferSize(g.window)
		if width > 0 && height > 0 do break
		glfw.WaitEvents()
	}

	vk_check(vk.DeviceWaitIdle(g.device))

	// colour and depth targets are sized to the swapchain, so they go along
	destroy_render_targets()
	destroy_swapchain()

	create_swapchain()
	get_swapchain_images()
	create_image_views()
	create_render_targets()
	recreate_render_finished_semaphores()
}

recreate_render_finished_semaphores :: proc() {
	for s in g.render_finished_semaphores {
		vk.DestroySemaphore(g.device, s, nil)
	}
	delete(g.render_finished_semaphores)

	semaphore_ci := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	g.render_finished_semaphores = make([]vk.Semaphore, len(g.swapchain_images))
	for i in 0 ..< len(g.swapchain_images) {
		vk_check(
			vk.CreateSemaphore(g.device, &semaphore_ci, nil, &g.render_finished_semaphores[i]),
		)
	}
}

destroy_sync_objects :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(g.device, g.image_available_semaphores[i], nil)
		vk.DestroyFence(g.device, g.in_flight_fences[i], nil)
	}
	for s in g.render_finished_semaphores {
		vk.DestroySemaphore(g.device, s, nil)
	}
	delete(g.render_finished_semaphores)
}

