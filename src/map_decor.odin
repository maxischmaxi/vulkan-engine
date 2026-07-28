package main

import "core:math/linalg"
import "game"

// Fences, railings and pillars as models, the same deal as the crates in
// map_props.odin: the map says where one stands -- every brush with a decor
// material is one -- and the brush keeps doing the collision while the mesh
// does the looking.
//
// Unlike a crate, a fence has a direction and a natural module length. A brush
// is therefore tiled along its long axis with pieces of roughly the module's
// width rather than stretched into one long blur, and pieces are rotated so
// their long side follows the run.

@(private = "file")
RAILING_MODELS := []string{"mod_railing"}
@(private = "file")
FENCE_MODELS := []string{"mod_fence", "mod_fence2", "mod_fence3"}
@(private = "file")
PILLAR_MODELS := []string{"mod_pillar", "mod_pillar2"}

@(private = "file")
Decor_Brush :: struct {
	min, max: [3]f32,
	material: game.Material_ID,
}

@(private = "file")
decor_brushes: [dynamic]Decor_Brush

// Runs before the world is baked, right beside mark_prop_brushes: the brush
// stops being drawn but stays in the collision bake, which never reads faces.
mark_decor_brushes :: proc(brushes: []game.Brush) {
	decor_brushes = make([dynamic]Decor_Brush, 0, 32)

	for &brush in brushes {
		material := game.Material_ID(brush.material)
		#partial switch material {
		case .Railing, .Fence, .Pillar:
		case:
			continue
		}
		append(&decor_brushes, Decor_Brush{min = brush.min, max = brush.max, material = material})
		brush.faces = {}
	}
}

// Same deterministic position hash as the crates use, so the same map always
// picks the same pieces.
@(private = "file")
decor_scramble :: proc(position: [3]f32) -> u32 {
	h := u32(2166136261)
	for value in position {
		h = (h ~ transmute(u32)value) * 16777619
	}
	h ~= h >> 15
	return h * 2246822519
}

// fit_transform with a quarter turn around Z folded in: the mesh's own bounds
// land on the box with its X axis rotated onto +X, +Y, -X or -Y. Odd turns swap
// which world extent each mesh axis has to cover.
@(private = "file")
fit_rotated :: proc(mesh: Mesh, mn, mx: [3]f32, quarter: int) -> linalg.Matrix4f32 {
	extent := mesh.bounds_max - mesh.bounds_min
	target := mx - mn

	odd := quarter % 2 == 1
	sx := (odd ? target.y : target.x) / max(extent.x, 1e-4)
	sy := (odd ? target.x : target.y) / max(extent.y, 1e-4)
	sz := target.z / max(extent.z, 1e-4)

	c: f32 = quarter == 0 ? 1 : quarter == 2 ? -1 : 0
	s: f32 = quarter == 1 ? 1 : quarter == 3 ? -1 : 0

	// The mesh origin sits at the middle of its footprint on the floor, so the
	// rotation happens in place and only the box centre and base matter.
	center := [3]f32{(mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, mn.z}

	m: linalg.Matrix4f32 = 1
	m[0, 0] = c * sx
	m[0, 1] = -s * sy
	m[1, 0] = s * sx
	m[1, 1] = c * sy
	m[2, 2] = sz
	m[0, 3] = center.x
	m[1, 3] = center.y
	m[2, 3] = center.z - mesh.bounds_min.z * sz
	return m
}

// Turns the marked brushes into placements, appended to the crates' list so
// everything still goes through one build_static_models upload.
append_decor_placements :: proc(placements: ^[dynamic]Model_Placement) {
	for brush in decor_brushes {
		size := brush.max - brush.min
		noise := decor_scramble(brush.min)

		if brush.material == .Pillar {
			name := PILLAR_MODELS[noise % u32(len(PILLAR_MODELS))]
			append(
				placements,
				Model_Placement {
					mesh = name,
					model = fit_rotated(find_mesh(name), brush.min, brush.max, int((noise >> 8) % 4)),
				},
			)
			continue
		}

		models := brush.material == .Fence ? FENCE_MODELS : RAILING_MODELS
		along_x := size.x >= size.y
		length := along_x ? size.x : size.y

		// The family shares one module width; the segments stretch a little to
		// cover the run exactly, which the flat palette colours absorb.
		module := find_mesh(models[0])
		module_len := module.bounds_max.x - module.bounds_min.x
		segments := max(1, int(length / module_len + 0.5))
		step := length / f32(segments)

		for i in 0 ..< segments {
			mn, mx := brush.min, brush.max
			if along_x {
				mn.x = brush.min.x + f32(i) * step
				mx.x = mn.x + step
			} else {
				mn.y = brush.min.y + f32(i) * step
				mx.y = mn.y + step
			}

			seg_noise := decor_scramble(mn)
			name := models[seg_noise % u32(len(models))]
			quarter := along_x ? 0 : 1
			// A half turn reverses the piece along its run for variety
			if (seg_noise >> 8) & 1 == 1 do quarter += 2

			append(
				placements,
				Model_Placement{mesh = name, model = fit_rotated(find_mesh(name), mn, mx, quarter)},
			)
		}
	}

	delete(decor_brushes)
	decor_brushes = nil
}
