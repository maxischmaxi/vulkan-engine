package main

import "core:log"
import "core:math/linalg"
import "physics"
import vk "vendor:vulkan"

// World convention: Z-up, right-handed, X=east, Y=north, Z=up, one unit = one
// metre. Same axes as Source/Hammer, so counter-strike intuitions carry over.

Face :: enum {
	NegX,
	PosX,
	NegY,
	PosY,
	NegZ,
	PosZ,
}

ALL_FACES :: bit_set[Face]{.NegX, .PosX, .NegY, .PosY, .NegZ, .PosZ}

// Faces that never face the player: the underside of anything resting on the
// ground, and the outward side of the map's outer shell.
NO_BOTTOM :: ALL_FACES - {.NegZ}

Brush :: struct {
	min, max: [3]f32,
	material: u32,
	faces:    bit_set[Face],
}

// Per-face basis. u_dir/v_dir span the face; v_dir points along growing texture
// v, which is downward on walls so textures stand upright. origin is the corner
// where u=0 and v=0.
Face_Basis :: struct {
	normal: [3]f32,
	u_dir:  [3]f32,
	v_dir:  [3]f32,
}

FACE_BASES := [Face]Face_Basis {
	.NegX = {normal = {-1, 0, 0}, u_dir = {0, -1, 0}, v_dir = {0, 0, -1}},
	.PosX = {normal = {1, 0, 0}, u_dir = {0, 1, 0}, v_dir = {0, 0, -1}},
	.NegY = {normal = {0, -1, 0}, u_dir = {1, 0, 0}, v_dir = {0, 0, -1}},
	.PosY = {normal = {0, 1, 0}, u_dir = {-1, 0, 0}, v_dir = {0, 0, -1}},
	.NegZ = {normal = {0, 0, -1}, u_dir = {1, 0, 0}, v_dir = {0, 1, 0}},
	.PosZ = {normal = {0, 0, 1}, u_dir = {1, 0, 0}, v_dir = {0, -1, 0}},
}

// The corner of the brush where u=0 and v=0, per face.
face_origin :: proc(b: Brush, face: Face) -> [3]f32 {
	switch face {
	case .NegX:
		return {b.min.x, b.max.y, b.max.z}
	case .PosX:
		return {b.max.x, b.min.y, b.max.z}
	case .NegY:
		return {b.min.x, b.min.y, b.max.z}
	case .PosY:
		return {b.max.x, b.max.y, b.max.z}
	case .NegZ:
		return {b.min.x, b.min.y, b.min.z}
	case .PosZ:
		return {b.min.x, b.max.y, b.max.z}
	}
	return {}
}

// Extent of the face along u and v.
face_extent :: proc(b: Brush, face: Face) -> (u_len, v_len: f32) {
	size := b.max - b.min
	switch face {
	case .NegX, .PosX:
		return size.y, size.z
	case .NegY, .PosY:
		return size.x, size.z
	case .NegZ, .PosZ:
		return size.x, size.y
	}
	return 0, 0
}

// The whole static map: one vertex buffer, one index buffer, one draw.
World_Renderer :: struct {
	vertex_buffer: vk.Buffer,
	vertex_memory: vk.DeviceMemory,
	index_buffer:  vk.Buffer,
	index_memory:  vk.DeviceMemory,
	index_count:   u32,
	pipeline:      Pipeline,
}

world_renderer: World_Renderer

world_vertices: [dynamic]Vertex
world_indices: [dynamic]u32

// Collision and raycast targets. Stripped of material and face information,
// because neither matters for hitting something -- and keeping them separate is
// what lets a broadphase slot in here later without touching gameplay code.
world_collision: []physics.Aabb

// Turns the visible parts of every brush face into two triangles in world space.
// UVs are a planar world-space projection measured in metres -- the shader
// divides by the material's uv_scale, so textures line up across brush
// boundaries no matter how the brushes are cut, and the tiling density stays
// tweakable at runtime.
//
// Which parts are visible is map_clip's problem; this only emits what it hands
// over. Collision is built from the brushes themselves, untouched by any of it.
bake_world :: proc(brushes: []Brush) {
	faces := clip_world_faces(brushes)
	defer delete(faces)

	when ODIN_DEBUG {
		verify_face_partition(faces)
	}

	world_vertices = make([dynamic]Vertex, 0, len(faces) * 4)
	world_indices = make([dynamic]u32, 0, len(faces) * 6)

	for f in faces {
		emit_face_quad(f)
	}

	world_collision = make([]physics.Aabb, len(brushes))
	for b, i in brushes {
		world_collision[i] = {
			min = b.min,
			max = b.max,
		}
	}

	when ODIN_DEBUG {
		verify_winding()
	}

	mn, mx := world_bounds(brushes)
	log.infof(
		"World: {} brushes, {} quads, {} vertices, {} triangles, {:.0f} x {:.0f} m, {:.1f} m tall",
		len(brushes),
		len(faces),
		len(world_vertices),
		len(world_indices) / 3,
		mx.x - mn.x,
		mx.y - mn.y,
		mx.z - mn.z,
	)
}

// One clipped rectangle, wound counter-clockwise seen from outside the brush.
//
// The corner order is the one bake_world used when a face was always a whole
// brush side: (u0,v1) (u1,v1) (u1,v0) (u0,v0). Whether that is counter-clockwise
// depends only on the face's basis, not on how large the rectangle is, so it
// stays correct for any sub-rectangle -- verify_winding checks every triangle
// regardless.
@(private = "file")
emit_face_quad :: proc(f: Baked_Face) {
	basis := FACE_BASES[f.face]

	// glTF convention: bitangent = cross(normal, tangent.xyz) * w.
	// We want that to come out as v_dir.
	expected := linalg.cross(basis.normal, basis.u_dir)
	handedness: f32 = linalg.dot(expected, basis.v_dir) > 0 ? 1 : -1

	base := u32(len(world_vertices))

	uvs := [4][2]f32 {
		{f.uv_min.x, f.uv_max.y},
		{f.uv_max.x, f.uv_max.y},
		{f.uv_max.x, f.uv_min.y},
		{f.uv_min.x, f.uv_min.y},
	}

	for uv in uvs {
		append(
			&world_vertices,
			Vertex {
				pos = face_uv_point(f.face, f.coord, uv),
				normal = basis.normal,
				tangent = {basis.u_dir.x, basis.u_dir.y, basis.u_dir.z, handedness},
				uv = uv,
				material = f.material,
			},
		)
	}

	append(&world_indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// Every triangle's winding must match its stored normal. Getting this wrong
// makes back-face culling hide exactly the surfaces that should be visible,
// which is tedious to diagnose by eye.
verify_winding :: proc() {
	for i := 0; i < len(world_indices); i += 3 {
		a := world_vertices[world_indices[i]]
		b := world_vertices[world_indices[i + 1]]
		c := world_vertices[world_indices[i + 2]]

		geometric := linalg.cross(b.pos - a.pos, c.pos - a.pos)
		if linalg.dot(geometric, a.normal) <= 0 {
			log.panicf("Triangle {} winds against its normal {}", i / 3, a.normal)
		}
	}
}

create_world_buffers :: proc() {
	world_renderer.vertex_buffer, world_renderer.vertex_memory = create_device_local_buffer(
		world_vertices[:],
		{.VERTEX_BUFFER},
	)
	world_renderer.index_buffer, world_renderer.index_memory = create_device_local_buffer(
		world_indices[:],
		{.INDEX_BUFFER},
	)
	world_renderer.index_count = u32(len(world_indices))
}

create_world_pipeline :: proc() {
	bindings := []vk.VertexInputBindingDescription{vertex_binding_description()}
	attributes := vertex_attribute_descriptions()

	world_renderer.pipeline = build_pipeline(
		{
			name = "world",
			vert_spv = WORLD_VERT_CODE,
			frag_spv = WORLD_FRAG_CODE,
			bindings = bindings,
			attributes = attributes[:],
			set_layouts = {descriptors.frame_layout, descriptors.material_layout},
			color_formats = {g.swapchain_format},
			depth_format = g.depth_format,
			samples = g.msaa_samples,
			spec = shadow_spec_constants(),
		},
	)
}

// The pipeline is not destroyed here: rebuild_renderer owns every pipeline,
// because a settings change has to drop and rebuild all of them together.
destroy_world :: proc() {
	destroy_buffer(world_renderer.vertex_buffer, world_renderer.vertex_memory)
	destroy_buffer(world_renderer.index_buffer, world_renderer.index_memory)
	delete(world_vertices)
	delete(world_indices)
	delete(world_collision)
}

bind_world_geometry :: proc(cmd: vk.CommandBuffer) {
	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &world_renderer.vertex_buffer, raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, world_renderer.index_buffer, 0, .UINT32)
}

// The entire map in one call -- world-space baked geometry needs no per-object
// state, so there is nothing to iterate over.
record_world_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	vk.CmdBindPipeline(cmd, .GRAPHICS, world_renderer.pipeline.pipeline)
	bind_frame_set(cmd, world_renderer.pipeline.layout, frame)
	bind_material_set(cmd, world_renderer.pipeline.layout)
	bind_world_geometry(cmd)
	vk.CmdDrawIndexed(cmd, world_renderer.index_count, 1, 0, 0, 0)
}

// Bounds of everything, which is what the load line reports the map's size from.
world_bounds :: proc(brushes: []Brush) -> (mn, mx: [3]f32) {
	mn = {max(f32), max(f32), max(f32)}
	mx = {min(f32), min(f32), min(f32)}
	for b in brushes {
		mn = linalg.min(mn, b.min)
		mx = linalg.max(mx, b.max)
	}
	return
}
