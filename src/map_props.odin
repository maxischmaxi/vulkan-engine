package main

import "core:log"
import "core:math/linalg"
import "game"

// The crates on dust2, as models rather than as textured boxes.
//
// Nothing new is placed by hand: the map already says where a crate stands --
// every brush with the Crate material is one -- and those brushes keep doing the
// collision. All this does is stop them from being drawn and stand models in the
// same volume, so what the player walks into is exactly what they see.
//
// A brush is usually bigger than one crate, so it is filled with a grid of them.
// Cells that end up fully inside the stack are skipped: nothing can see a crate
// with crates on all six sides.

// Roughly what one crate should measure. Grid divisions come out of this, so it
// is also the dial between "a wall of tiny boxes" and "one stretched crate".
PROP_TILE :: [3]f32{1.1, 1.1, 1.0}

// A stack this deep is a bug in the map, not a crate pile.
MAX_PROP_INSTANCES_TOTAL :: 512

// The crate models, picked per cell. All four are boxy enough to survive being
// fitted to a cell that is not their own proportion.
CRATE_MODELS := []string{"prop_crate_01", "prop_crate_02", "prop_box_01", "prop_box_02"}

// Anything this large stopped being a crate pile: one container fills it instead.
CONTAINER_EDGE :: f32(3.0)

@(private = "file")
Prop_Brush :: struct {
	min, max: [3]f32,
}

@(private = "file")
prop_brushes: [dynamic]Prop_Brush

// Runs before the world is baked: a brush with no faces bakes to nothing, and
// bake_collision never looks at the face set, so the crate stays solid while
// disappearing from the render mesh.
mark_prop_brushes :: proc(brushes: []game.Brush) {
	prop_brushes = make([dynamic]Prop_Brush, 0, 32)

	for &brush in brushes {
		if brush.material != u32(game.Material_ID.Crate) do continue
		append(&prop_brushes, Prop_Brush{min = brush.min, max = brush.max})
		brush.faces = {}
	}
}

// Deterministic per-position noise, so the same map always produces the same
// pile and nothing has to be stored to keep it that way.
@(private = "file")
scramble :: proc(position: [3]f32) -> u32 {
	h := u32(2166136261)
	for value in position {
		h = (h ~ transmute(u32)value) * 16777619
	}
	// One more round, because the low bits of an FNV hash of three floats that
	// differ in the last decimal are not on their own well spread.
	h ~= h >> 15
	return h * 2246822519
}

// Box that fills the given extent with the model's own bounds mapped onto it.
// The scale is per axis: a crate model stretched into a cell reads as a bigger
// crate, which is the point, and the shader handles the skewed normals.
@(private = "file")
fit_transform :: proc(mesh: Mesh, mn, mx: [3]f32, flip: bool) -> linalg.Matrix4f32 {
	extent := mesh.bounds_max - mesh.bounds_min
	target := mx - mn

	scale := [3]f32 {
		extent.x > 1e-4 ? target.x / extent.x : 1,
		extent.y > 1e-4 ? target.y / extent.y : 1,
		extent.z > 1e-4 ? target.z / extent.z : 1,
	}

	// The model's own origin sits at the middle of its footprint on the floor
	// (convert_models.py puts it there), so only the centre of the cell and its
	// base are needed to place it.
	center := [3]f32{(mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, mn.z}

	m: linalg.Matrix4f32 = 1
	m[0, 0] = flip ? -scale.x : scale.x
	m[1, 1] = flip ? -scale.y : scale.y
	m[2, 2] = scale.z
	m[0, 3] = center.x
	m[1, 3] = center.y
	m[2, 3] = center.z - mesh.bounds_min.z * scale.z
	return m
}

// Runs after the meshes are loaded. Turns every marked brush into the models
// that fill it and hands the lot to the renderer, which uploads them once.
place_map_props :: proc() {
	placements := make([dynamic]Model_Placement, 0, 128)
	defer delete(placements)

	for brush in prop_brushes {
		size := brush.max - brush.min

		// A shipping container is a single model, not a pile: at this size a
		// grid of crates reads as a wall and costs twenty draws.
		if max(size.x, size.y) >= CONTAINER_EDGE && size.z >= 2.0 {
			name := size.x > size.y ? "prop_container_02" : "prop_container_01"
			mesh := find_mesh(name)
			// container_01 runs along y, container_02 along x; the one whose
			// long axis already matches needs no rotating
			append(
				&placements,
				Model_Placement {
					mesh = name,
					model = fit_transform(mesh, brush.min, brush.max, false),
				},
			)
			continue
		}

		tile := PROP_TILE
		counts: [3]int
		for axis in 0 ..< 3 {
			counts[axis] = max(1, int(size[axis] / tile[axis] + 0.5))
		}

		cell := [3]f32{size.x / f32(counts[0]), size.y / f32(counts[1]), size.z / f32(counts[2])}

		for ix in 0 ..< counts[0] {
			for iy in 0 ..< counts[1] {
				for iz in 0 ..< counts[2] {
					// Interior cells are sealed in on all six sides
					inside :=
						ix > 0 &&
						ix < counts[0] - 1 &&
						iy > 0 &&
						iy < counts[1] - 1 &&
						iz > 0 &&
						iz < counts[2] - 1
					if inside do continue

					mn := brush.min + {cell.x * f32(ix), cell.y * f32(iy), cell.z * f32(iz)}
					noise := scramble(mn)

					name := CRATE_MODELS[noise % u32(len(CRATE_MODELS))]
					append(
						&placements,
						Model_Placement {
							mesh = name,
							model = fit_transform(
								find_mesh(name),
								mn,
								mn + cell,
								(noise >> 8) & 1 == 1,
							),
						},
					)
				}
			}
		}
	}

	brush_count := len(prop_brushes)
	append_decor_placements(&placements)

	if len(placements) > MAX_PROP_INSTANCES_TOTAL {
		log.warnf(
			"{} prop instances from {} brushes -- raise PROP_TILE if this is a frame-rate problem",
			len(placements),
			brush_count,
		)
	}

	build_static_models(placements[:])
	delete(prop_brushes)
	prop_brushes = nil
}
