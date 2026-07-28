package main

import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

// Imported geometry: the weapon viewmodels and the map's props, baked out of
// the asset archives by `just models` into a format this file can hand almost
// straight to a vertex buffer.
//
// The layout is the world's own Vertex (see vertex.odin), which is why there is
// no conversion step here and no second lighting path in the shaders: a model
// triangle is a world triangle that happens to carry a model matrix.
//
// Every mesh lands in one shared pair of buffers. The map does the same thing
// for the same reason -- a draw is then a range, and nothing has to be rebound
// between two models.

MESH_DIR :: "models"
MESH_MAGIC :: u32le(0x4853_4D44) // "DMSH"
MESH_VERSION :: 1
MESH_NAME_LEN :: 32

// Mirrors the header convert_models.py writes. All fields are 4-byte, so the
// vertex block that follows needs no padding to stay aligned.
Mesh_Header :: struct {
	magic:          u32le,
	version:        u32le,
	vertex_count:   u32le,
	index_count:    u32le,
	material_count: u32le,
	bounds_min:     [3]f32,
	bounds_max:     [3]f32,
}

#assert(size_of(Mesh_Header) == 44)

// A loaded mesh is a range into the shared buffers plus the box it occupies.
// The bounds are in model space, which is what the prop placement measures
// against when it fits a crate model into a brush.
Mesh :: struct {
	first_index: u32,
	index_count: u32,
	base_vertex: i32,
	bounds_min:  [3]f32,
	bounds_max:  [3]f32,
}

Mesh_Store :: struct {
	vertex_buffer: vk.Buffer,
	vertex_memory: vk.DeviceMemory,
	index_buffer:  vk.Buffer,
	index_memory:  vk.DeviceMemory,
	meshes:        map[string]Mesh,
	// Filled while loading, uploaded once at the end: a device-local buffer per
	// mesh would be dozens of allocations for a few megabytes in total.
	vertices:      [dynamic]Vertex,
	indices:       [dynamic]u32,
	loaded:        bool,
}

mesh_store: Mesh_Store

// The material names convert_models.py writes, mapped to indices into MATERIALS.
// Written out rather than derived so that reordering the material table cannot
// silently re-texture every model, and an unknown name stops the load.
mesh_material_index :: proc(name: string) -> (u32, bool) {
	switch name {
	case "retro_arms":
		return MODEL_MAT_RETRO_ARMS, true
	case "retro_guns":
		return MODEL_MAT_RETRO_GUNS, true
	case "prop_palette":
		return MODEL_MAT_PROP_PALETTE, true
	case "gun_matte":
		return MODEL_MAT_GUN_MATTE, true
	case "gun_metal":
		return MODEL_MAT_GUN_METAL, true
	case "mod_palette":
		return MODEL_MAT_MOD_PALETTE, true
	}
	return 0, false
}

// Reads one .mesh into the pending arrays. The file's per-vertex material field
// is a local slot; it is rewritten here into the engine's material index.
@(private = "file")
load_mesh :: proc(name: string) -> bool {
	path := strings.concatenate({MESH_DIR, "/", name, ".mesh"}, context.temp_allocator)

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("{}: {}", path, err)
		return false
	}
	if len(data) < size_of(Mesh_Header) {
		log.errorf("{}: truncated", path)
		return false
	}

	header := (^Mesh_Header)(raw_data(data))^
	if header.magic != MESH_MAGIC || header.version != MESH_VERSION {
		log.errorf("{}: not a version {} mesh", path, MESH_VERSION)
		return false
	}

	names_offset := size_of(Mesh_Header)
	vertex_offset := names_offset + int(header.material_count) * MESH_NAME_LEN
	vertex_bytes := int(header.vertex_count) * size_of(Vertex)
	index_bytes := int(header.index_count) * size_of(u32)

	if len(data) < vertex_offset + vertex_bytes + index_bytes {
		log.errorf("{}: truncated body", path)
		return false
	}

	// Local slot -> MATERIALS index, resolved once for the whole file.
	slots := make([]u32, int(header.material_count), context.temp_allocator)
	for i in 0 ..< int(header.material_count) {
		raw := data[names_offset + i * MESH_NAME_LEN:][:MESH_NAME_LEN]
		end := MESH_NAME_LEN
		if terminator, found := slice.linear_search(raw, u8(0)); found {
			end = terminator
		}
		index, ok := mesh_material_index(string(raw[:end]))
		if !ok {
			log.errorf("{}: unknown material {:q}", path, string(raw[:end]))
			return false
		}
		slots[i] = index
	}

	base_vertex := i32(len(mesh_store.vertices))
	first_index := u32(len(mesh_store.indices))

	vertices := mem.slice_data_cast([]Vertex, data[vertex_offset:][:vertex_bytes])
	for vertex in vertices {
		v := vertex
		if int(v.material) >= len(slots) {
			log.errorf("{}: vertex points at material slot {}", path, v.material)
			return false
		}
		v.material = slots[v.material]
		append(&mesh_store.vertices, v)
	}

	indices := mem.slice_data_cast([]u32, data[vertex_offset + vertex_bytes:][:index_bytes])
	append(&mesh_store.indices, ..indices)

	mesh_store.meshes[strings.clone(name)] = Mesh {
		first_index = first_index,
		index_count = u32(header.index_count),
		base_vertex = base_vertex,
		bounds_min  = header.bounds_min,
		bounds_max  = header.bounds_max,
	}
	return true
}

// Everything the client draws as a mesh. Props are listed by the placement code
// that picks between them; adding one here is what makes it available.
MESH_FILES := []string {
	"view_ak",
	"view_m4",
	"view_awp",
	"view_mac10",
	"view_mp9",
	"view_nova",
	"view_glock",
	"view_usp",
	"view_deagle",
	"view_knife",
	"prop_crate_01",
	"prop_crate_02",
	"prop_box_01",
	"prop_box_02",
	"prop_barrel_01",
	"prop_barrel_03",
	"prop_barrel_04",
	"prop_container_01",
	"prop_container_02",
	"prop_eur_pallet",
	"prop_locker",
	"prop_storagerack_01",
	"prop_electricbox_01",
	"prop_garbagecan",
	"prop_suitcase_01",
	"mod_fence",
	"mod_fence2",
	"mod_fence3",
	"mod_railing",
	"mod_pillar",
	"mod_pillar2",
}

create_mesh_store :: proc() {
	mesh_store.meshes = make(map[string]Mesh, len(MESH_FILES))
	mesh_store.vertices = make([dynamic]Vertex, 0, 64 * 1024)
	mesh_store.indices = make([dynamic]u32, 0, 128 * 1024)

	failed := 0
	for name in MESH_FILES {
		if !load_mesh(name) do failed += 1
		free_all(context.temp_allocator)
	}

	if failed > 0 {
		log.panicf(
			"{} of {} meshes failed to load -- run `just models` to build them",
			failed,
			len(MESH_FILES),
		)
	}

	mesh_store.vertex_buffer, mesh_store.vertex_memory = create_device_local_buffer(
		mesh_store.vertices[:],
		{.VERTEX_BUFFER},
	)
	mesh_store.index_buffer, mesh_store.index_memory = create_device_local_buffer(
		mesh_store.indices[:],
		{.INDEX_BUFFER},
	)
	mesh_store.loaded = true

	log.infof(
		"Meshes: {} models, {} vertices, {} triangles, {:.1f} MB",
		len(MESH_FILES),
		len(mesh_store.vertices),
		len(mesh_store.indices) / 3,
		f64(len(mesh_store.vertices) * size_of(Vertex) + len(mesh_store.indices) * size_of(u32)) /
		(1024 * 1024),
	)

	// The CPU copies have done their job once both buffers exist.
	delete(mesh_store.vertices)
	delete(mesh_store.indices)
	mesh_store.vertices = nil
	mesh_store.indices = nil
}

destroy_mesh_store :: proc() {
	if !mesh_store.loaded do return
	destroy_buffer(mesh_store.vertex_buffer, mesh_store.vertex_memory)
	destroy_buffer(mesh_store.index_buffer, mesh_store.index_memory)
	for name in mesh_store.meshes {
		delete(name)
	}
	delete(mesh_store.meshes)
}

// Panics rather than returning ok: every caller names a mesh from MESH_FILES,
// so a miss is a typo in the source, not a runtime condition.
find_mesh :: proc(name: string) -> Mesh {
	mesh, ok := mesh_store.meshes[name]
	if !ok do log.panicf("no mesh {:q} -- add it to MESH_FILES", name)
	return mesh
}
