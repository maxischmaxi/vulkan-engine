package game

import "core:log"
import "core:slice"

// Which parts of a brush face are actually visible.
//
// A map is written as boxes that freely overlap -- an L-corner is two walls that
// both claim the corner block, a floor sits inside the ground, a rock mass is
// pushed through a wall until the silhouette looks right. That is the whole
// point of authoring with boxes, and it is why map_dust2 reads the way it does.
//
// The renderer cannot draw it that way. Two faces on the same plane facing the
// same direction give the depth buffer no way to choose between them, so it
// picks differently from one pixel and one frame to the next, and the surface
// flickers. Pushing one of them a hair forward would only move the problem to
// wherever the hair is too small.
//
// So the geometry stops overlapping before it ever reaches the GPU: every brush
// face is cut down to the part nothing else hides or claims, and what comes out
// is a partition -- no two visible faces are coplanar, same-facing and
// overlapping. map_check asserts exactly that on the output, so the flicker
// cannot come back no matter what a future map does.
//
// Brushes themselves are left alone. world_collision is built from the same
// array, and the player must still collide with what the author drew.

// The axis each face's plane is perpendicular to.
FACE_AXIS := [Face]int {
	.NegX = 0,
	.PosX = 0,
	.NegY = 1,
	.PosY = 1,
	.NegZ = 2,
	.PosZ = 2,
}

// Which way the face looks along that axis, +1 or -1. Read off the basis rather
// than tabulated a second time, so a normal is written down in one place only.
face_dir :: proc(face: Face) -> f32 {
	return FACE_BASES[face].normal[FACE_AXIS[face]]
}

// A rectangle of brush face that survived clipping, stated in the face's own
// (u,v) space -- which is also exactly its UV rectangle, because the shader's
// UVs are a world-space planar projection onto the same two axes. Nothing has to
// be reprojected on the way to the vertex buffer.
//
// `face` alone determines the axis and the outward direction, so there is no
// second copy of either that could fall out of step with it.
Baked_Face :: struct {
	face:     Face,
	coord:    f32, // the plane's coordinate along FACE_AXIS[face]
	uv_min:   [2]f32,
	uv_max:   [2]f32,
	material: u32,
	brush:    int, // diagnostics only; nothing downstream reads it
}

// The brush's extent along one of the six signed axis vectors. Negating when the
// vector points the other way is the reason no caller ever has to think about
// FACE_BASES' sign conventions -- that v runs downward on walls, and that PosZ's
// v_dir points at -y.
axis_range :: proc(b: Brush, w: [3]f32) -> (lo, hi: f32) {
	k := 0
	if w.y != 0 do k = 1
	if w.z != 0 do k = 2

	if w[k] > 0 do return b.min[k], b.max[k]
	return -b.max[k], -b.min[k]
}

// The face's rectangle in its own (u,v) space.
face_uv_rect :: proc(b: Brush, face: Face) -> (uv_min, uv_max: [2]f32) {
	basis := FACE_BASES[face]
	u0, u1 := axis_range(b, basis.u_dir)
	v0, v1 := axis_range(b, basis.v_dir)
	return {u0, v0}, {u1, v1}
}

// Where the face's plane sits along its axis.
face_coord :: proc(b: Brush, face: Face) -> f32 {
	ax := FACE_AXIS[face]
	return face_dir(face) > 0 ? b.max[ax] : b.min[ax]
}

// The world point on `face`'s plane at texture coordinate `uv`. The inverse of
// the shader's projection, and what makes an arbitrary sub-rectangle of a face
// emittable without going back to the brush it was cut from.
//
// u_dir and v_dir are both zero on the face's own axis, so the plane coordinate
// is written rather than accumulated -- every emitted coordinate is then bit for
// bit one of the numbers the map was authored with.
face_uv_point :: proc(face: Face, coord: f32, uv: [2]f32) -> [3]f32 {
	basis := FACE_BASES[face]
	p := basis.u_dir * uv.x + basis.v_dir * uv.y
	p[FACE_AXIS[face]] = coord
	return p
}

// Switch the clipping off and emit every authored face whole, which is what the
// renderer did before this file existed. Nothing but a bisection tool: if a wall
// grows a hole, this says in one build whether the clipper put it there.
MAP_CLIP :: #config(MAP_CLIP, true)

// ---------------------------------------------------------------- tolerances
//
// All of them are justified against one number: the thinnest thing the map is
// allowed to contain is FLOOR_SLAB, 6 cm. Coordinates reach here from float
// literals through a handful of additions, so they carry at most ~1e-4 of
// rounding; every tolerance below sits above that and far under 6 cm.

// Two plane coordinates this close are one plane.
PLANE_EPS :: f32(1e-3)

// How far past a plane a brush has to reach before it counts as solid on that
// side. Without it a brush merely flush with the plane would bury it.
SOLID_EPS :: f32(1e-3)

// Two cut lines this close within one plane are one line. Tighter than
// PLANE_EPS because these are the same authored numbers arriving by the same
// route, not two numbers arriving by different ones.
WELD_EPS :: f32(1e-4)

// A surviving rectangle thinner than this is a rounding artefact rather than
// geometry. Dropping it leaves a millimetre of nothing, which beats a degenerate
// quad -- and it says so out loud, because if this ever fires the map has grown
// a feature finer than the clipper can see.
MIN_EDGE :: f32(1e-3)

@(private = "file")
Rect2 :: struct {
	mn, mx: [2]f32,
}

// Reused across all 882 faces rather than reallocated per face. The largest
// grid the current map produces is 87 x 73, for the ground.
@(private = "file")
Clip_Scratch :: struct {
	cutters: [dynamic]Rect2,
	clipped: [dynamic]Rect2,
	pieces:  [dynamic]Rect2,
	us, vs:  [dynamic]f32,
	edges:   [dynamic]f32,
	covered: [dynamic]bool,
}

// Faces sort into planes: Face determines both the axis and the outward
// direction, so grouping by it and then by coordinate puts every face sharing a
// plane in one contiguous run.
plane_less :: proc(a, b: Baked_Face) -> bool {
	if a.face != b.face do return a.face < b.face
	return a.coord < b.coord
}

// How much of two coplanar faces is claimed by both. Zero when they only touch.
face_overlap_area :: proc(a, b: Baked_Face) -> f32 {
	u := min(a.uv_max.x, b.uv_max.x) - max(a.uv_min.x, b.uv_min.x)
	v := min(a.uv_max.y, b.uv_max.y) - max(a.uv_min.y, b.uv_min.y)
	if u <= MIN_EDGE || v <= MIN_EDGE do return 0
	return u * v
}

@(private = "file")
face_area :: proc(f: Baked_Face) -> f32 {
	return (f.uv_max.x - f.uv_min.x) * (f.uv_max.y - f.uv_min.y)
}

// Which of two coplanar faces keeps the ground they both claim.
//
// The larger authored face wins, so a long wall's texture runs unbroken through
// a corner instead of being interrupted by the 60 cm one that meets it there.
// Ties fall back to authoring order, which makes the outcome deterministic and
// gives the author the only lever they need: if a corner ever resolves to the
// wrong material, shrink the losing brush in the map -- do not special-case this.
//
// It is a strict total order, because (area, brush) is unique among the faces of
// one plane. That is what makes the survivors a partition rather than a pile:
// every point is kept by exactly the highest-ranked face covering it.
@(private = "file")
face_outranks :: proc(a, b: Baked_Face) -> bool {
	area_a, area_b := face_area(a), face_area(b)
	if area_a != area_b do return area_a > area_b
	if a.brush != b.brush do return a.brush < b.brush
	return a.face < b.face
}

// Does this brush fill the space immediately outside the plane?
//
// The two sides are deliberately not symmetric. "Starts at or before the plane"
// is tolerant, so a brush authored a hair past it still counts; "reaches
// genuinely outward" is strict, so a brush merely ending on the plane does not
// bury the face it is flush with. The owning brush fails the strict side by
// construction, which is why nothing here compares indices.
@(private = "file")
brush_seals :: proc(b: Brush, ax: int, dir, coord: f32) -> bool {
	if dir > 0 {
		return b.min[ax] <= coord + PLANE_EPS && b.max[ax] >= coord + SOLID_EPS
	}
	return b.max[ax] >= coord - PLANE_EPS && b.min[ax] <= coord - SOLID_EPS
}

// Every part of every brush face that nothing else hides or claims. The result
// is a partition: no two entries are coplanar, same-facing and overlapping, and
// together they cover exactly what a camera outside the solid can see.
// Allocates; the caller owns the slice.
clip_world_faces :: proc(brushes: []Brush, allocator := context.allocator) -> []Baked_Face {
	faces := make([dynamic]Baked_Face, 0, len(brushes) * 6, context.temp_allocator)
	for b, i in brushes {
		for face in Face {
			if face not_in b.faces do continue

			uv_min, uv_max := face_uv_rect(b, face)
			append(
				&faces,
				Baked_Face {
					face = face,
					coord = face_coord(b, face),
					uv_min = uv_min,
					uv_max = uv_max,
					material = b.material,
					brush = i,
				},
			)
		}
	}

	// `when` splices into the enclosing scope rather than opening one, so this
	// name has to stay clear of the clipped path's below.
	when !MAP_CLIP {
		log.warn("Map: face clipping is off -- coplanar surfaces will z-fight")
		whole := make([]Baked_Face, len(faces), allocator)
		copy(whole, faces[:])
		return whole
	}

	slice.sort_by(faces[:], plane_less)

	out := make([dynamic]Baked_Face, 0, len(faces) * 2, allocator)

	scratch: Clip_Scratch
	defer {
		delete(scratch.cutters)
		delete(scratch.clipped)
		delete(scratch.pieces)
		delete(scratch.us)
		delete(scratch.vs)
		delete(scratch.edges)
		delete(scratch.covered)
	}

	hidden := 0
	ledger: Arbitration_Ledger

	for start := 0; start < len(faces); {
		// One plane is one contiguous run. The step is measured against the
		// previous face rather than the run's first, so two faces within
		// PLANE_EPS of each other always land in the same run -- with the map's
		// coordinates either equal or centimetres apart, no run ever drifts
		// wider than the tolerance.
		end := start + 1
		for end < len(faces) &&
		    faces[end].face == faces[start].face &&
		    faces[end].coord - faces[end - 1].coord <= PLANE_EPS {
			end += 1
		}

		plane := faces[start:end]
		note_arbitrations(&ledger, plane)

		for f, fi in plane {
			clear(&scratch.cutters)

			ax := FACE_AXIS[f.face]
			dir := face_dir(f.face)

			// Buried: something solid fills the space just outside this face.
			for b in brushes {
				if !brush_seals(b, ax, dir, f.coord) do continue

				mn, mx := face_uv_rect(b, f.face)
				append(&scratch.cutters, Rect2{mn, mx})
			}

			// Outranked: a coplanar neighbour has the better claim to the overlap.
			//
			// Both kinds of cut go into one list because they commute. Burial
			// depends only on the plane and the point, never on which face owns
			// it, so two coplanar faces are buried identically wherever they
			// overlap -- there is no order in which arbitration could hand a
			// region to a face that burial then removes.
			for other, oi in plane {
				if oi == fi do continue
				if !face_outranks(other, f) do continue

				append(&scratch.cutters, Rect2{other.uv_min, other.uv_max})
			}

			clear(&scratch.pieces)
			subtract_rects(&scratch, f.uv_min, f.uv_max)

			if len(scratch.pieces) == 0 {
				hidden += 1
				continue
			}

			for p in scratch.pieces {
				piece := f
				piece.uv_min = p.mn
				piece.uv_max = p.mx
				append(&out, piece)
			}
		}

		start = end
	}

	log.infof(
		"Map: clipper -- {} of {} faces hidden by neighbours, {} coplanar overlaps arbitrated",
		hidden,
		len(faces),
		ledger.count,
	)
	if ledger.count > 0 {
		log.infof(
			"Map: largest arbitration {:.1f} m2 -- brush {} {} yields to brush {} {} on {} at {:.3f}",
			ledger.area,
			ledger.loser.brush,
			Material_ID(ledger.loser.material),
			ledger.winner.brush,
			Material_ID(ledger.winner.material),
			ledger.winner.face,
			ledger.winner.coord,
		)
	}

	return out[:]
}

// What the clipper decided, for the log. A silently wrong arbitration is not an
// error -- verify_face_partition cannot see it, because the output is a valid
// partition either way. This line is the only thing that can surface one.
@(private = "file")
Arbitration_Ledger :: struct {
	count:         int,
	area:          f32,
	winner, loser: Baked_Face,
}

@(private = "file")
note_arbitrations :: proc(ledger: ^Arbitration_Ledger, plane: []Baked_Face) {
	for i in 0 ..< len(plane) {
		for j in i + 1 ..< len(plane) {
			area := face_overlap_area(plane[i], plane[j])
			if area <= 0 do continue

			ledger.count += 1
			if area <= ledger.area do continue

			ledger.area = area
			ledger.winner, ledger.loser = plane[i], plane[j]
			if face_outranks(ledger.loser, ledger.winner) {
				ledger.winner, ledger.loser = ledger.loser, ledger.winner
			}
		}
	}
}

// `rect` minus the union of `scratch.cutters`, as a small set of rectangles
// appended to `scratch.pieces`.
//
// Coordinate compression: the cut lines are the only places the answer can
// change, so the rectangle is diced along exactly those and nowhere else. The
// cutters are clipped to the rectangle before their edges are gathered, which is
// what keeps the grid small -- the ground's 138 cutters produce 87 x 73 cells,
// not 277 x 277.
@(private = "file")
subtract_rects :: proc(s: ^Clip_Scratch, mn, mx: [2]f32) {
	if mx.x - mn.x <= MIN_EDGE || mx.y - mn.y <= MIN_EDGE do return

	clear(&s.clipped)
	for c in s.cutters {
		r := Rect2 {
			mn = {max(c.mn.x, mn.x), max(c.mn.y, mn.y)},
			mx = {min(c.mx.x, mx.x), min(c.mx.y, mx.y)},
		}
		if r.mx.x - r.mn.x <= MIN_EDGE || r.mx.y - r.mn.y <= MIN_EDGE do continue

		// covers the whole face: nothing survives, and no grid is needed
		if r.mn.x <= mn.x && r.mn.y <= mn.y && r.mx.x >= mx.x && r.mx.y >= mx.y do return

		append(&s.clipped, r)
	}

	if len(s.clipped) == 0 {
		append(&s.pieces, Rect2{mn, mx})
		return
	}

	gather_edges(s, &s.us, mn.x, mx.x, 0)
	gather_edges(s, &s.vs, mn.y, mx.y, 1)

	nu := len(s.us) - 1
	nv := len(s.vs) - 1

	resize(&s.covered, nu * nv)
	slice.fill(s.covered[:], false)

	// Rasterised by index range rather than tested per cell: the cost is the
	// area a cutter covers, not the grid times the cutter count.
	for c in s.clipped {
		i0 := cell_index(s.us[:], c.mn.x)
		i1 := cell_index(s.us[:], c.mx.x)
		j0 := cell_index(s.vs[:], c.mn.y)
		j1 := cell_index(s.vs[:], c.mx.y)

		for j in j0 ..< j1 {
			for i in i0 ..< i1 {
				s.covered[j * nu + i] = true
			}
		}
	}

	// Merging rows with identical coverage is not an optimisation, it is what
	// makes the output usable: without it the ground alone would emit 6351 quads
	// instead of 129. Identical coverage is also what keeps the emitted
	// rectangles from overlapping each other.
	for j := 0; j < nv; {
		k := j + 1
		for k < nv && slice.equal(s.covered[j * nu:][:nu], s.covered[k * nu:][:nu]) {
			k += 1
		}

		for i := 0; i < nu; {
			if s.covered[j * nu + i] {
				i += 1
				continue
			}

			e := i + 1
			for e < nu && !s.covered[j * nu + e] do e += 1

			r := Rect2 {
				mn = {s.us[i], s.vs[j]},
				mx = {s.us[e], s.vs[k]},
			}
			if r.mx.x - r.mn.x > MIN_EDGE && r.mx.y - r.mn.y > MIN_EDGE {
				append(&s.pieces, r)
			}
			i = e
		}

		j = k
	}
}

// The rectangle's own two edges plus every cut line strictly between them,
// sorted, with coincident ones welded into one.
@(private = "file")
gather_edges :: proc(s: ^Clip_Scratch, out: ^[dynamic]f32, lo, hi: f32, axis: int) {
	clear(&s.edges)
	append(&s.edges, lo, hi)

	for c in s.clipped {
		if c.mn[axis] > lo && c.mn[axis] < hi do append(&s.edges, c.mn[axis])
		if c.mx[axis] > lo && c.mx[axis] < hi do append(&s.edges, c.mx[axis])
	}
	slice.sort(s.edges[:])

	clear(out)
	for x in s.edges {
		if len(out) == 0 || x - out[len(out) - 1] > WELD_EPS do append(out, x)
	}
}

// The cell `x` starts at. Every value asked about is a welded edge or within
// WELD_EPS of one, so this is a lookup rather than a search for the nearest.
@(private = "file")
cell_index :: proc(edges: []f32, x: f32) -> int {
	i := 0
	for i + 1 < len(edges) && edges[i + 1] <= x + WELD_EPS do i += 1
	return i
}
