package main

import "core:log"
import "core:math/linalg"
import "game"
import "physics"
import vk "vendor:vulkan"

// The render half of the world. The brushes themselves -- Brush, Face, the
// face bases, collision baking -- live in the game package, because the server
// walks the same map without ever drawing it.

// The whole static map: one vertex buffer, one index buffer, one draw.
World_Renderer :: struct {
	vertex_buffer: vk.Buffer,
	vertex_memory: vk.DeviceMemory,
	index_buffer:  vk.Buffer,
	index_memory:  vk.DeviceMemory,
	index_count:   u32,
	pipeline:      Pipeline,
	overdraw_pipe: Pipeline, // debug view F12: additive heatmap of shaded fragments
	prepass_pipe:  Pipeline, // depth-only first pass, absent with --no-depth-prepass
}

world_renderer: World_Renderer

world_vertices: [dynamic]Vertex
world_indices: [dynamic]u32

// Turns the visible parts of every brush face into two triangles in world space.
// UVs are a planar world-space projection measured in metres -- the shader
// divides by the material's uv_scale, so textures line up across brush
// boundaries no matter how the brushes are cut, and the tiling density stays
// tweakable at runtime.
//
// Which parts are visible is map_clip's problem; this only emits what it hands
// over. Collision is built from the brushes themselves, untouched by any of it.
bake_world :: proc(brushes: []game.Brush) {
	faces := game.clip_world_faces(brushes)
	defer delete(faces)

	when ODIN_DEBUG {
		verify_face_partition(faces)
	}

	// groups the faces by brush and records each brush's index range, so the
	// emit loop below has to run over the same order
	build_world_order(faces, brushes)

	world_vertices = make([dynamic]Vertex, 0, len(faces) * 4)
	world_indices = make([dynamic]u32, 0, len(faces) * 6)

	for f in faces {
		emit_face_quad(f)
	}

	// Collision and its broadphase live on the shared game state, so the
	// simulation -- local or server-side -- walks exactly this bake.
	gs.collision = game.bake_collision(brushes)
	gs.grid = physics.grid_build(gs.collision)

	when ODIN_DEBUG {
		verify_winding()
	}

	mn, mx := game.world_bounds(brushes)
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
emit_face_quad :: proc(f: game.Baked_Face) {
	basis := game.FACE_BASES[f.face]

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
				pos = game.face_uv_point(f.face, f.coord, uv),
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
	create_world_order_buffers()
}

create_world_pipeline :: proc() {
	bindings := []vk.VertexInputBindingDescription{vertex_binding_description()}
	attributes := vertex_attribute_descriptions()

	// With the prepass, depth is already final when the shading pass runs: only
	// fragments that match what the prepass wrote survive, and nothing needs
	// writing again. gl_Position is invariant in both shaders, which is what
	// makes the GREATER_OR_EQUAL an equality test in practice.
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
			depth_test = cli.depth_prepass ? .Nearer_Or_Equal : .Nearer,
			no_depth_write = cli.depth_prepass,
			spec = shadow_spec_constants(),
		},
	)

	position_only := position_attribute_description()

	if cli.depth_prepass {
		world_renderer.prepass_pipe = build_pipeline(
			{
				name = "world/prepass",
				vert_spv = PREPASS_VERT_CODE,
				bindings = bindings,
				attributes = position_only[:],
				set_layouts = {descriptors.frame_layout},
				color_formats = {g.swapchain_format},
				no_color_write = true,
				depth_format = g.depth_format,
				samples = g.msaa_samples,
			},
		)
	}

	// Same depth state as the real pass, so the heatmap counts exactly the
	// fragments the real pass would shade.
	world_renderer.overdraw_pipe = build_pipeline(
		{
			name = "world/overdraw",
			vert_spv = WORLD_VERT_CODE,
			frag_spv = OVERDRAW_FRAG_CODE,
			bindings = bindings,
			attributes = attributes[:],
			set_layouts = {descriptors.frame_layout},
			color_formats = {g.swapchain_format},
			depth_format = g.depth_format,
			samples = g.msaa_samples,
			blend = .Additive,
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
	destroy_world_order()
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

bind_world_geometry :: proc(cmd: vk.CommandBuffer) {
	offsets := []vk.DeviceSize{0}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &world_renderer.vertex_buffer, raw_data(offsets))
	vk.CmdBindIndexBuffer(cmd, world_renderer.index_buffer, 0, .UINT32)
}

// The entire map in one call -- world-space baked geometry needs no per-object
// state, so there is nothing to iterate over. Indices come front-to-back from
// this frame's sorted buffer; the shadow pass keeps the static one.
record_world_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if cli.depth_prepass {
		vk.CmdBindPipeline(cmd, .GRAPHICS, world_renderer.prepass_pipe.pipeline)
		bind_frame_set(cmd, world_renderer.prepass_pipe.layout, frame)
		bind_world_sorted(cmd, frame)
		vk.CmdDrawIndexed(cmd, world_renderer.index_count, 1, 0, 0, 0)
	}

	vk.CmdBindPipeline(cmd, .GRAPHICS, world_renderer.pipeline.pipeline)
	bind_frame_set(cmd, world_renderer.pipeline.layout, frame)
	bind_material_set(cmd, world_renderer.pipeline.layout)
	bind_world_sorted(cmd, frame)
	vk.CmdDrawIndexed(cmd, world_renderer.index_count, 1, 0, 0, 0)
}

// The heatmap alone, on the depth state the real pass would have used. Props
// and decals are deliberately absent so the picture answers one question: how
// much does the world shade that the player never sees.
record_world_overdraw :: proc(cmd: vk.CommandBuffer, frame: u32) {
	vk.CmdBindPipeline(cmd, .GRAPHICS, world_renderer.overdraw_pipe.pipeline)
	bind_frame_set(cmd, world_renderer.overdraw_pipe.layout, frame)
	bind_world_sorted(cmd, frame)
	vk.CmdDrawIndexed(cmd, world_renderer.index_count, 1, 0, 0, 0)
}
