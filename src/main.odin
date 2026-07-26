package main

import "base:runtime"
import "core:log"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

MAX_FRAMES_IN_FLIGHT :: 2

// The Vulkan context and nothing else: instance, device, swapchain, render
// targets, frame synchronisation. Everything a feature owns lives with that
// feature -- world_renderer in world.odin, prop_renderer in prop_render.odin,
// shadow in shadow.odin, and so on.
//
// That split is the point. This struct is touched when the Vulkan setup itself
// changes, which is rarely; adding gameplay or a new pass does not come near it,
// so two people adding two features do not collide here.
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
	// Set by the window callback. Waiting for the driver to report OUT_OF_DATE
	// works on most of them, but "most" is not a resize policy, and a compositor
	// that resizes to a size the driver still considers valid would leave the
	// projection matching a window that no longer exists.
	framebuffer_resized:        bool,
	command_pool:               vk.CommandPool,
	command_buffers:            [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight_fences:           [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	render_finished_semaphores: []vk.Semaphore, // one per swapchain image
	current_frame:              u32,
	msaa_samples:               vk.SampleCountFlags,
	color_image:                vk.Image, // multisampled, resolved into the swapchain
	color_memory:               vk.DeviceMemory,
	color_view:                 vk.ImageView,
	depth_image:                vk.Image,
	depth_memory:               vk.DeviceMemory,
	depth_view:                 vk.ImageView,
	depth_format:               vk.Format,
	anisotropy_enabled:         bool,
	max_anisotropy:             f32,
	validation_enabled:         bool,
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

	glfw.SetFramebufferSizeCallback(
		g.window,
		proc "c" (window: glfw.WindowHandle, width, height: i32) {
			context = g.odin_context
			g.framebuffer_resized = true
		},
	)

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

	// ---------------------------------------------------------------- scene
	brushes := build_dust2()
	defer delete(brushes)

	bake_world(brushes)
	create_world_buffers()

	create_material_buffer()
	defer destroy_material_buffer()

	create_texture_arrays()
	create_texture_sampler()
	defer destroy_texture_arrays()

	init_lights()
	defer destroy_lights()

	create_shadow_map()

	// --------------------------------------------------------------- render
	// Layouts describe shapes only, so they come before the resources; the sets
	// that point at those resources come after everything exists.
	create_descriptor_layouts()
	create_descriptor_pool()
	defer destroy_descriptors()

	create_frame_data()
	defer destroy_frame_data()

	create_prop_renderer()
	create_decal_renderer()

	create_descriptor_sets()

	create_world_pipeline()
	defer destroy_world()

	create_shadow_pipelines()
	defer destroy_shadow_map()

	create_prop_pipeline()
	defer destroy_prop_renderer()

	create_decal_pipeline()
	defer destroy_decal_renderer()

	create_hud_pipeline()
	defer destroy_hud_renderer()

	create_command_buffers()

	create_sync_objects()
	defer destroy_sync_objects()

	// ----------------------------------------------------------- game state
	init_camera()
	init_player()
	init_bots(brushes)
	init_weapons()

	init_input()
	defer destroy_input()
	log_input_support()

	init_clock()

	for !glfw.WindowShouldClose(g.window) {
		free_all(context.temp_allocator)
		glfw.PollEvents()
		update()
		draw_frame()
	}

	vk_check(vk.DeviceWaitIdle(g.device))
}

// One frame's worth of everything that is not drawing.
//
// The order here is the whole point of the fixed tick: look direction is applied
// immediately from the mouse, the simulation advances in whole steps, and the
// renderer is handed a blend factor between the last two of them.
update :: proc() {
	steps := advance_clock()

	poll_keys()
	handle_hotkeys()

	// Aiming is never tick-quantised -- a frame of latency between the mouse
	// moving and the view following is the one thing a shooter cannot have.
	if input.cursor_grabbed {
		dx, dy := consume_mouse_delta()
		camera_apply_mouse(dx, dy)
		gather_player_intent()
	}

	for _ in 0 ..< steps {
		tick_player(TICK_DT)
		tick_bots(TICK_DT)
	}

	sync_camera_to_player(clock.alpha)

	// Firing runs on real time against the interpolated world, so it has to come
	// after the camera is where the player sees it.
	update_weapon(clock.frame_dt, clock.alpha)
	update_transient_lights(clock.frame_dt)

	update_cascades()
	build_frame(clock.alpha)

	log_frame_stats(clock.frame_dt)
}

@(private = "file")
handle_hotkeys :: proc() {
	if key_pressed(glfw.KEY_ESCAPE) && input.cursor_grabbed {
		grab_cursor(false)
	}

	if key_pressed(glfw.KEY_F1) do set_debug_mode(.None)
	if key_pressed(glfw.KEY_F2) do set_debug_mode(.Cascades)
	if key_pressed(glfw.KEY_F3) do set_debug_mode(.Albedo)
	if key_pressed(glfw.KEY_F4) do set_debug_mode(.Normals)
	if key_pressed(glfw.KEY_F5) do set_debug_mode(.Lighting)

	if key_pressed(glfw.KEY_F6) {
		clear_decals()
		log.info("Decals cleared")
	}
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

	alive := 0
	for bot in bots {
		if bot.alive do alive += 1
	}

	log.infof(
		"{:.1f} fps ({:.2f} ms)  pos {:.1f} {:.1f} {:.1f}  {} {}/{} hits  {} bots  {} decals{}",
		f32(frames) / accum,
		accum / f32(frames) * 1000,
		player.body.position.x,
		player.body.position.y,
		player.body.position.z,
		current_weapon().name,
		weapon_state.hits,
		weapon_state.shots,
		alive,
		decal_renderer.count,
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
			log.warnf(
				"{} unavailable, continuing without validation",
				vk.EXT_DEBUG_UTILS_EXTENSION_NAME,
			)
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

// `old` is handed to the driver rather than destroyed up front, so it can reuse
// the images behind it. Dragging a window edge asks for a rebuild on every pixel
// of travel, and a full reallocation each time is what makes a resize stutter.
create_swapchain :: proc(old: vk.SwapchainKHR = {}) {
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
		oldSwapchain     = old,
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

// The views and the image list belong to the swapchain they came from, so they
// always go together. The handle itself is separate, because a rebuild passes it
// on as oldSwapchain before letting go of it.
destroy_swapchain_views :: proc() {
	for view in g.swapchain_views {
		vk.DestroyImageView(g.device, view, nil)
	}
	delete(g.swapchain_views)
	delete(g.swapchain_images)
}

destroy_swapchain :: proc() {
	destroy_swapchain_views()
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

recreate_swapchain :: proc() {
	g.framebuffer_resized = false

	// wait out minimization: a zero-sized framebuffer cannot back a swapchain
	for {
		width, height := glfw.GetFramebufferSize(g.window)
		if width > 0 && height > 0 do break
		glfw.WaitEvents()
	}

	vk_check(vk.DeviceWaitIdle(g.device))

	// colour and depth targets are sized to the swapchain, so they go along
	destroy_render_targets()
	destroy_swapchain_views()

	// The wait above means nothing is still reading the old swapchain, so it can
	// go as soon as the new one has taken what it needs from it.
	old := g.swapchain
	create_swapchain(old)
	vk.DestroySwapchainKHR(g.device, old, nil)

	get_swapchain_images()
	create_image_views()
	create_render_targets()
	recreate_render_finished_semaphores()

	// The window changed shape, so the field of view did too. Logging it here
	// makes dragging the window something to read off rather than squint at.
	log_camera_fov()
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
