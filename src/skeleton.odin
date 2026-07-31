package main

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import vk "vendor:vulkan"

// The player character: one skinned mesh and the rig that moves it, baked out
// of the Quaternius animation library by `just models` (tools/convert_characters.py).
//
// Two files rather than one, because they answer to different things. The .skin
// is geometry and changes when the model does; the .skel is the rig and the clip
// library, and grows every time the animation code learns a new move. Sharing a
// file would mean rebuilding both to add a clip.
//
// What the format leaves out is as deliberate as what it keeps. There is no
// scale track, because nothing in the library scales a bone; there is one
// translation track rather than 65, because only the pelvis translates. Both are
// checked by the converter, which stops with the joint's name rather than
// quietly dropping motion.

SKEL_MAGIC :: u32le(0x4C4B_5344) // "DSKL"
SKIN_MAGIC :: u32le(0x4E4B_5344) // "DSKN"
SKEL_VERSION :: 1

CHARACTER_SKELETON :: "mannequin"

// The engine's cap, not the format's -- the vertex joint indices are u8, so the
// file could carry far more. This is what the per-frame joint buffer is sized
// against, so it is a number worth having to raise deliberately.
MAX_SKELETON_JOINTS :: 80

// ---------------------------------------------------------------- file layout

Skel_Header :: struct {
	magic:        u32le,
	version:      u32le,
	joint_count:  u32le,
	clip_count:   u32le,
	motion_joint: u32le, // the one joint whose translation is animated
	total_frames: u32le, // clip frames end to end, the length of the pose arrays
	_pad:         [2]u32le,
}

#assert(size_of(Skel_Header) == 32)

// inverse_bind is a flat array rather than a Matrix4f32 because Odin aligns
// that type to 32 and would pad this struct away from the file's layout.
Skel_Joint_File :: struct {
	name:             [MESH_NAME_LEN]u8,
	parent:           i32le, // -1 for the root
	rest_translation: [3]f32,
	inverse_bind:     [16]f32, // column-major, as written and as Odin stores it
}

#assert(size_of(Skel_Joint_File) == 112)

Skel_Clip_File :: struct {
	name:         [MESH_NAME_LEN]u8,
	first_frame:  u32le,
	frame_count:  u32le,
	fps:          f32,
	flags:        u32le,
	displacement: [3]f32,
	_pad:         f32,
}

#assert(size_of(Skel_Clip_File) == 64)

CLIP_FLAG_LOOP :: u32(1 << 0)

Skin_Header :: struct {
	magic:          u32le,
	version:        u32le,
	vertex_count:   u32le,
	index_count:    u32le,
	material_count: u32le,
	joint_count:    u32le, // has to agree with the skeleton this skin is posed by
	bounds_min:     [3]f32,
	bounds_max:     [3]f32,
}

#assert(size_of(Skin_Header) == 48)

// ------------------------------------------------------------------- runtime

Joint :: struct {
	parent:           i32,
	rest_translation: [3]f32,
	inverse_bind:     linalg.Matrix4f32,
}

Anim_Clip :: struct {
	first_frame:  u32,
	frame_count:  u32,
	fps:          f32,
	loop:         bool,
	// How far the root travels in one cycle, measured off the root-motion copy
	// of the library. The locomotion blend advances the phase by speed over
	// this, which is what puts a foot on the ground where the ground is instead
	// of at a stride length picked by hand.
	displacement: [3]f32,
}

Skeleton :: struct {
	joints:       []Joint,
	names:        []string,
	clips:        map[string]Anim_Clip,
	// Pose data for every clip end to end: one rotation per joint per frame,
	// and the motion joint's translation per frame. A clip is a range, the same
	// way a mesh is a range into the shared vertex buffer.
	rotations:    []quaternion128,
	motion:       [][3]f32,
	motion_joint: int,
	loaded:       bool,
}

Skin_Mesh :: struct {
	vertex_buffer: vk.Buffer,
	vertex_memory: vk.DeviceMemory,
	index_buffer:  vk.Buffer,
	index_memory:  vk.DeviceMemory,
	index_count:   u32,
	bounds_min:    [3]f32,
	bounds_max:    [3]f32,
	loaded:        bool,
}

character_skeleton: Skeleton
character_skin: Skin_Mesh

skeleton_joint_count :: proc() -> int {
	return len(character_skeleton.joints)
}

// Panics rather than returning ok, for the same reason find_mesh does: every
// caller names a clip the converter's roster puts in the file, so a miss is a
// typo in the source and not a runtime condition.
find_clip :: proc(name: string) -> Anim_Clip {
	clip, ok := character_skeleton.clips[name]
	if !ok do log.panicf("no clip {:q} -- add it to CLIPS in tools/convert_characters.py", name)
	return clip
}

// The joint a weapon or an effect hangs off. Resolved once at load; a missing
// name is a rig change, which is worth stopping for.
skeleton_joint_index :: proc(name: string) -> int {
	for joint_name, i in character_skeleton.names {
		if joint_name == name do return i
	}
	log.panicf("no joint {:q} in the {} skeleton", name, CHARACTER_SKELETON)
}

// -------------------------------------------------------------------- loading

@(private = "file")
character_path :: proc(extension: string) -> string {
	return strings.concatenate(
		{MESH_DIR, "/", CHARACTER_SKELETON, extension},
		context.temp_allocator,
	)
}

@(private = "file")
file_name :: proc(raw: []u8) -> string {
	end := len(raw)
	if terminator, found := slice.linear_search(raw, u8(0)); found {
		end = terminator
	}
	return string(raw[:end])
}

@(private = "file")
load_skeleton :: proc() -> bool {
	path := character_path(".skel")

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("{}: {}", path, err)
		return false
	}
	if len(data) < size_of(Skel_Header) {
		log.errorf("{}: truncated", path)
		return false
	}

	header := (^Skel_Header)(raw_data(data))^
	if header.magic != SKEL_MAGIC || header.version != SKEL_VERSION {
		log.errorf("{}: not a version {} skeleton", path, SKEL_VERSION)
		return false
	}

	joint_count := int(header.joint_count)
	if joint_count > MAX_SKELETON_JOINTS {
		log.errorf("{}: {} joints exceeds MAX_SKELETON_JOINTS", path, joint_count)
		return false
	}

	clip_count := int(header.clip_count)
	total_frames := int(header.total_frames)

	joints_offset := size_of(Skel_Header)
	clips_offset := joints_offset + joint_count * size_of(Skel_Joint_File)
	rotations_offset := clips_offset + clip_count * size_of(Skel_Clip_File)
	rotation_bytes := total_frames * joint_count * 4 * size_of(f32)
	motion_bytes := total_frames * 3 * size_of(f32)

	if len(data) < rotations_offset + rotation_bytes + motion_bytes {
		log.errorf("{}: truncated body", path)
		return false
	}

	s := &character_skeleton
	s.joints = make([]Joint, joint_count)
	s.names = make([]string, joint_count)
	s.motion_joint = int(header.motion_joint)

	files := mem.slice_data_cast(
		[]Skel_Joint_File,
		data[joints_offset:][:joint_count * size_of(Skel_Joint_File)],
	)
	for &f, i in files {
		// Parents come before their children, which is what lets the pose walk
		// the array once instead of recursing. The converter guarantees it; this
		// is what catches a file that says otherwise.
		if int(f.parent) >= i {
			log.errorf("{}: joint {} points at parent {}", path, i, f.parent)
			return false
		}
		m: linalg.Matrix4f32
		for column in 0 ..< 4 {
			for row in 0 ..< 4 {
				m[row, column] = f.inverse_bind[column * 4 + row]
			}
		}
		s.joints[i] = {
			parent           = i32(f.parent),
			rest_translation = f.rest_translation,
			inverse_bind     = m,
		}
		s.names[i] = strings.clone(file_name(f.name[:]))
	}

	s.clips = make(map[string]Anim_Clip, clip_count)
	clip_files := mem.slice_data_cast(
		[]Skel_Clip_File,
		data[clips_offset:][:clip_count * size_of(Skel_Clip_File)],
	)
	for &f in clip_files {
		if int(f.first_frame) + int(f.frame_count) > total_frames {
			log.errorf("{}: clip {:q} runs past the pose data", path, file_name(f.name[:]))
			return false
		}
		s.clips[strings.clone(file_name(f.name[:]))] = Anim_Clip {
			first_frame  = u32(f.first_frame),
			frame_count  = u32(f.frame_count),
			fps          = f.fps,
			loop         = (u32(f.flags) & CLIP_FLAG_LOOP) != 0,
			displacement = f.displacement,
		}
	}

	// Quaternions are read component-wise rather than cast: the file's (x, y, z, w)
	// order is the format's promise, Odin's in-memory order is not.
	raw_rotations := mem.slice_data_cast([][4]f32, data[rotations_offset:][:rotation_bytes])
	s.rotations = make([]quaternion128, len(raw_rotations))
	for q, i in raw_rotations {
		s.rotations[i] = quaternion(x = q[0], y = q[1], z = q[2], w = q[3])
	}

	raw_motion := mem.slice_data_cast([][3]f32, data[rotations_offset + rotation_bytes:][:motion_bytes])
	s.motion = make([][3]f32, len(raw_motion))
	copy(s.motion, raw_motion)

	s.loaded = true
	log.infof(
		"Skeleton: {} joints, {} clips, {} pose frames",
		joint_count,
		clip_count,
		total_frames,
	)
	return true
}

@(private = "file")
load_skin :: proc() -> bool {
	path := character_path(".skin")

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		log.errorf("{}: {}", path, err)
		return false
	}
	if len(data) < size_of(Skin_Header) {
		log.errorf("{}: truncated", path)
		return false
	}

	header := (^Skin_Header)(raw_data(data))^
	if header.magic != SKIN_MAGIC || header.version != SKEL_VERSION {
		log.errorf("{}: not a version {} skin", path, SKEL_VERSION)
		return false
	}
	if int(header.joint_count) != len(character_skeleton.joints) {
		log.errorf(
			"{}: posed by {} joints, the skeleton has {}",
			path,
			header.joint_count,
			len(character_skeleton.joints),
		)
		return false
	}

	names_offset := size_of(Skin_Header)
	vertex_offset := names_offset + int(header.material_count) * MESH_NAME_LEN
	vertex_bytes := int(header.vertex_count) * size_of(Skin_Vertex)
	index_bytes := int(header.index_count) * size_of(u32)

	if len(data) < vertex_offset + vertex_bytes + index_bytes {
		log.errorf("{}: truncated body", path)
		return false
	}

	// Local slot -> MATERIALS index, the same resolution mesh.odin does. The
	// names the converter writes are the T side; the CT instance reaches its own
	// rows through the instance's material offset.
	slots := make([]u32, int(header.material_count), context.temp_allocator)
	for i in 0 ..< int(header.material_count) {
		name := file_name(data[names_offset + i * MESH_NAME_LEN:][:MESH_NAME_LEN])
		index, ok := mesh_material_index(name)
		if !ok {
			log.errorf("{}: unknown material {:q}", path, name)
			return false
		}
		slots[i] = index
	}

	source := mem.slice_data_cast([]Skin_Vertex, data[vertex_offset:][:vertex_bytes])
	vertices := make([]Skin_Vertex, len(source), context.temp_allocator)
	for vertex, i in source {
		v := vertex
		if int(v.material) >= len(slots) {
			log.errorf("{}: vertex points at material slot {}", path, v.material)
			return false
		}
		v.material = slots[v.material]
		vertices[i] = v
	}

	indices := mem.slice_data_cast([]u32, data[vertex_offset + vertex_bytes:][:index_bytes])

	character_skin.vertex_buffer, character_skin.vertex_memory = create_device_local_buffer(
		vertices,
		{.VERTEX_BUFFER},
	)
	character_skin.index_buffer, character_skin.index_memory = create_device_local_buffer(
		indices,
		{.INDEX_BUFFER},
	)
	character_skin.index_count = u32(header.index_count)
	character_skin.bounds_min = header.bounds_min
	character_skin.bounds_max = header.bounds_max
	character_skin.loaded = true

	log.infof(
		"Character: {} vertices, {} triangles, {:.1f} m tall",
		header.vertex_count,
		int(header.index_count) / 3,
		header.bounds_max.z - header.bounds_min.z,
	)
	return true
}

create_skeleton_store :: proc() {
	ok := load_skeleton()
	if ok do ok = load_skin()
	free_all(context.temp_allocator)

	if !ok {
		log.panicf("the character failed to load -- run `just models` to build it")
	}

	// Resolves the clip roster and the aim joints by name, now that both exist.
	character_anim_init()
}

destroy_skeleton_store :: proc() {
	if character_skin.loaded {
		destroy_buffer(character_skin.vertex_buffer, character_skin.vertex_memory)
		destroy_buffer(character_skin.index_buffer, character_skin.index_memory)
	}
	if !character_skeleton.loaded do return

	for name in character_skeleton.names {
		delete(name)
	}
	for name in character_skeleton.clips {
		delete(name)
	}
	delete(character_skeleton.clips)
	delete(character_skeleton.names)
	delete(character_skeleton.joints)
	delete(character_skeleton.rotations)
	delete(character_skeleton.motion)
}
