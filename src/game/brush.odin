package game

import "../physics"
import "core:math/linalg"

// The map's building block, shared by both binaries: the client bakes render
// meshes out of brushes, the server only ever needs the collision boxes.
//
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

// Collision and raycast targets, stripped of material and face information --
// neither matters for hitting something. Both binaries run this over the same
// brush list in the same order, so the arrays come out bit-identical, which is
// what lets the client predict against the server's world.
bake_collision :: proc(brushes: []Brush, allocator := context.allocator) -> []physics.Aabb {
	collision := make([]physics.Aabb, len(brushes), allocator)
	for b, i in brushes {
		collision[i] = {
			min = b.min,
			max = b.max,
		}
	}
	return collision
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
