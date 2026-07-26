package main

import "core:math/linalg"
import "core:mem"
import vk "vendor:vulkan"

// Bullet holes. A ring buffer of quads laid flat on whatever was hit, oldest
// overwritten once it is full, so this never grows and never allocates during
// play.

MAX_DECALS :: 256

// The quad, not the hole: the hole itself is about a third of this and the rest
// is the pulverised ring around it. A rifle round through plaster takes out
// noticeably more than its own calibre.
DECAL_SIZE :: 0.16

// Pushed off the surface so the quad is unambiguously in front of it. This alone
// is not enough across a 250 m far plane, which is why the pipeline also carries
// a negative depth bias.
DECAL_OFFSET :: 0.002

Decal_Vertex :: struct {
	pos:   [3]f32,
	// local coordinates in [-1,1]; the fragment shader draws the hole from these
	local: [2]f32,
	seed:  f32,
}

#assert(size_of(Decal_Vertex) == 24)

Decal_Renderer :: struct {
	vertex_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	vertex_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	vertex_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	index_buffer:    vk.Buffer,
	index_memory:    vk.DeviceMemory,
	pipeline:        Pipeline,
	vertices:        [MAX_DECALS * 4]Decal_Vertex,
	count:           int, // decals placed so far, capped at MAX_DECALS
	next:            int, // ring cursor
	dirty:           bool,
}

decal_renderer: Decal_Renderer

decal_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Decal_Vertex), inputRate = .VERTEX}
}

decal_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Decal_Vertex, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Decal_Vertex, local)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32_SFLOAT,
			offset = u32(offset_of(Decal_Vertex, seed)),
		},
	}
}

create_decal_renderer :: proc() {
	// The index pattern never changes, so it lives in device memory and is built
	// once for the full ring.
	indices := make([]u32, MAX_DECALS * 6, context.temp_allocator)
	for i in 0 ..< MAX_DECALS {
		base := u32(i * 4)
		indices[i * 6 + 0] = base
		indices[i * 6 + 1] = base + 1
		indices[i * 6 + 2] = base + 2
		indices[i * 6 + 3] = base
		indices[i * 6 + 4] = base + 2
		indices[i * 6 + 5] = base + 3
	}
	decal_renderer.index_buffer, decal_renderer.index_memory = create_device_local_buffer(
		indices,
		{.INDEX_BUFFER},
	)

	size := vk.DeviceSize(len(decal_renderer.vertices) * size_of(Decal_Vertex))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		decal_renderer.vertex_buffers[i], decal_renderer.vertex_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				decal_renderer.vertex_memories[i],
				0,
				size,
				{},
				&decal_renderer.vertex_mapped[i],
			),
		)
	}
}

create_decal_pipeline :: proc() {
	bindings := []vk.VertexInputBindingDescription{decal_binding_description()}
	attributes := decal_attribute_descriptions()

	decal_renderer.pipeline = build_pipeline(
		{
			name           = "decals",
			vert_spv       = DECAL_VERT_CODE,
			frag_spv       = DECAL_FRAG_CODE,
			bindings       = bindings,
			attributes     = attributes[:],
			set_layouts    = {descriptors.frame_layout},
			color_formats  = {g.swapchain_format},
			depth_format   = g.depth_format,
			samples        = g.msaa_samples,
			// Coplanar with the wall it sits on: test against it, never write, and
			// bias toward the camera so the comparison resolves in our favour.
			depth_test     = .Less_Equal,
			no_depth_write = true,
			blend          = .Alpha,
			depth_bias     = true,
			// no culling: a decal is a flat quad and the basis below may wind
			// either way depending on which face was hit
			cull           = .None,
		},
	)
}

destroy_decal_renderer :: proc() {
	destroy_pipeline(decal_renderer.pipeline)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, decal_renderer.vertex_memories[i])
		destroy_buffer(decal_renderer.vertex_buffers[i], decal_renderer.vertex_memories[i])
	}
	destroy_buffer(decal_renderer.index_buffer, decal_renderer.index_memory)
}

// Any two vectors perpendicular to the normal will do; picking the world axis
// least aligned with it keeps the cross product well conditioned.
@(private = "file")
surface_basis :: proc(normal: [3]f32) -> (right, up: [3]f32) {
	reference := [3]f32{0, 0, 1}
	if abs(normal.z) > 0.9 {
		reference = {1, 0, 0}
	}
	right = linalg.normalize(linalg.cross(reference, normal))
	up = linalg.cross(normal, right)
	return
}

add_decal :: proc(point, normal: [3]f32, seed: f32) {
	right, up := surface_basis(normal)

	half := f32(DECAL_SIZE) * 0.5
	center := point + normal * DECAL_OFFSET

	slot := decal_renderer.next
	decal_renderer.next = (decal_renderer.next + 1) % MAX_DECALS
	decal_renderer.count = min(decal_renderer.count + 1, MAX_DECALS)

	corners := [4][2]f32{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}
	for c, i in corners {
		decal_renderer.vertices[slot * 4 + i] = {
			pos   = center + right * (c.x * half) + up * (c.y * half),
			local = c,
			seed  = seed,
		}
	}

	decal_renderer.dirty = true
}

clear_decals :: proc() {
	decal_renderer.count = 0
	decal_renderer.next = 0
	decal_renderer.dirty = true
}

// The whole ring is copied rather than tracking which slots changed: 24 KB is
// well below the point where the bookkeeping would pay for itself.
upload_decals :: proc(frame: u32) {
	if decal_renderer.count == 0 do return

	mem.copy(
		decal_renderer.vertex_mapped[frame],
		raw_data(&decal_renderer.vertices),
		decal_renderer.count * 4 * size_of(Decal_Vertex),
	)
}

record_decal_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if decal_renderer.count == 0 do return

	vk.CmdBindPipeline(cmd, .GRAPHICS, decal_renderer.pipeline.pipeline)
	bind_frame_set(cmd, decal_renderer.pipeline.layout, frame)

	// Negative bias pulls the quad toward the camera in depth. Slope scaling
	// matters here because a decal seen at a glancing angle spans many depth
	// values across a single pixel.
	vk.CmdSetDepthBias(cmd, -2.0, 0, -2.0)

	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &decal_renderer.vertex_buffers[frame], raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, decal_renderer.index_buffer, 0, .UINT32)

	vk.CmdDrawIndexed(cmd, u32(decal_renderer.count * 6), 1, 0, 0, 0)
}
