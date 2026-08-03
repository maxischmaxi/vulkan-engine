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

// What a decal is a mark of. Both are drawn from the same quad by the same
// shader; only the pattern differs, which is why this is a vertex attribute
// rather than a second pipeline.
Decal_Kind :: enum u8 {
	Hole, // a bullet: dark core, pale rim
	Scorch, // a blast: a wide soot smudge with no core
}

Decal_Vertex :: struct {
	pos:   [3]f32,
	// local coordinates in [-1,1]; the fragment shader draws the mark from these
	local: [2]f32,
	seed:  f32,
	kind:  f32,
}

#assert(size_of(Decal_Vertex) == 28)

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
	// One per frame in flight: a single bullet dirties every copy of the buffer,
	// not just the one about to be written.
	dirty:           [MAX_FRAMES_IN_FLIGHT]bool,
}

decal_renderer: Decal_Renderer

decal_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Decal_Vertex), inputRate = .VERTEX}
}

decal_attribute_descriptions :: proc() -> [4]vk.VertexInputAttributeDescription {
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
		{
			location = 3,
			binding = 0,
			format = .R32_SFLOAT,
			offset = u32(offset_of(Decal_Vertex, kind)),
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
			depth_test     = .Nearer_Or_Equal,
			no_depth_write = true,
			blend          = .Alpha,
			depth_bias     = true,
			// no culling: a decal is a flat quad and the basis below may wind
			// either way depending on which face was hit
			cull           = .None,
			spec           = shadow_spec_constants(),
		},
	)
}

destroy_decal_renderer :: proc() {

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, decal_renderer.vertex_memories[i])
		destroy_buffer(decal_renderer.vertex_buffers[i], decal_renderer.vertex_memories[i])
	}
	destroy_buffer(decal_renderer.index_buffer, decal_renderer.index_memory)
}

// Any two vectors perpendicular to the normal will do; picking the world axis
// least aligned with it keeps the cross product well conditioned.
//
// Package-visible because anything laid flat on a surface needs it -- the
// throw preview's impact ring is drawn on exactly this basis.
surface_basis :: proc(normal: [3]f32) -> (right, up: [3]f32) {
	reference := [3]f32{0, 0, 1}
	if abs(normal.z) > 0.9 {
		reference = {1, 0, 0}
	}
	right = linalg.normalize(linalg.cross(reference, normal))
	up = linalg.cross(normal, right)
	return
}

// `size` is the full width of the quad; the default is one bullet's worth.
add_decal :: proc(
	point, normal: [3]f32,
	seed: f32,
	size: f32 = DECAL_SIZE,
	kind := Decal_Kind.Hole,
) {
	right, up := surface_basis(normal)

	half := size * 0.5
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
			kind  = f32(kind),
		}
	}

	for &d in decal_renderer.dirty do d = true
}

clear_decals :: proc() {
	decal_renderer.count = 0
	decal_renderer.next = 0
	for &d in decal_renderer.dirty do d = true
}

// The whole ring is copied rather than tracking which slots changed: 24 KB is
// well below the point where per-slot bookkeeping would pay for itself. Whether
// to copy at all is worth tracking though -- decals change when a bullet lands
// and not otherwise, so the overwhelming majority of frames skip this entirely.
upload_decals :: proc(frame: u32) {
	if decal_renderer.count == 0 do return
	if !decal_renderer.dirty[frame] do return
	decal_renderer.dirty[frame] = false

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

	// Positive bias pulls the quad toward the camera, because under reversed-Z
	// nearer is greater. Slope scaling matters here because a decal seen at a
	// glancing angle spans many depth values across a single pixel.
	vk.CmdSetDepthBias(cmd, 2.0, 0, 2.0)

	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &decal_renderer.vertex_buffers[frame], raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, decal_renderer.index_buffer, 0, .UINT32)

	vk.CmdDrawIndexed(cmd, u32(decal_renderer.count * 6), 1, 0, 0, 0)
}
