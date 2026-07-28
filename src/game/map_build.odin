package game

// The vocabulary a map is written in. Everything the level geometry needs and
// nothing about any particular level -- the layout itself lives in map_dust2.
//
// Every piece is an axis-aligned box, which is what lets one array serve as
// render geometry, collision volume and raycast target at once. The price is
// that nothing can lean, so slopes are built out of steps; the player's 0.45 m
// step-up swallows anything shorter than that without a jump, which is why a
// staircase of 0.3 m treads walks like a ramp and collides like a box.

WALL_H :: 5.0 // inner walls, high enough that you cannot see over them
OUTER_H :: 10.0 // map shell
WALL_T :: 0.6 // wall thickness
GROUND_Z :: 0.0 // top of the ground plane

// Indoor flooring laid on top of the ground rather than cut into it: a 6 cm slab
// is real geometry, so there is no z-fighting to worry about.
FLOOR_SLAB :: 0.06

// How thick a roof is, and how far a doorway's lintel sits above the floor under
// it. The clearance is well over the 1.8 m player so a doorway reads as a
// doorway rather than as something to duck through.
ROOF_T :: 0.4
DOOR_CLEARANCE :: 2.6

// The tallest a step may be before it stops feeling like a slope. Comfortably
// under STEP_HEIGHT, because a step exactly at the limit catches whenever the
// body is a hair low.
RAMP_STEP_RISE :: 0.3

// Boxes given as a footprint plus a height, which is how nearly every brush in
// a shooter map is actually shaped.
wall :: proc(
	x0, y0, x1, y1: f32,
	material: Material_ID,
	height: f32 = WALL_H,
	base: f32 = GROUND_Z,
) -> Brush {
	return {
		min = {min(x0, x1), min(y0, y1), base},
		max = {max(x0, x1), max(y0, y1), base + height},
		material = u32(material),
		faces = NO_BOTTOM,
	}
}

// Free-floating box that can be seen from below (platforms, crates on ledges).
box :: proc(x0, y0, z0, x1, y1, z1: f32, material: Material_ID) -> Brush {
	return {
		min = {min(x0, x1), min(y0, y1), min(z0, z1)},
		max = {max(x0, x1), max(y0, y1), max(z0, z1)},
		material = u32(material),
		faces = ALL_FACES,
	}
}

// A walkable surface with its top at `top`. Solid all the way down to the ground
// plane, so there is never a cavity under a floor to fall into or shoot through.
// At ground level it thins out to a slab laid over the ground, which keeps the
// two from sharing a plane and therefore from z-fighting.
add_floor :: proc(
	out: ^[dynamic]Brush,
	x0, y0, x1, y1, top: f32,
	material: Material_ID = .Floor_Indoor,
) {
	append(out, wall(x0, y0, x1, y1, material, max(top - GROUND_Z, FLOOR_SLAB)))
}

// Indoor flooring at ground level: a slab laid on top of the ground rather than
// cut into it, which is what everything indoors stands on.
add_slab :: proc(
	out: ^[dynamic]Brush,
	x0, y0, x1, y1: f32,
	material: Material_ID = .Floor_Indoor,
) {
	append(out, wall(x0, y0, x1, y1, material, FLOOR_SLAB))
}

// A roof over a corridor, given the height its underside hangs at.
add_ceiling :: proc(
	out: ^[dynamic]Brush,
	x0, y0, x1, y1, bottom: f32,
	material: Material_ID = .Wall_Trim,
) {
	append(out, box(x0, y0, bottom, x1, y1, bottom + ROOF_T, material))
}

// A slope, as steps. `z0` is the height at the x0/y0 end and `z1` at the other,
// so a ramp is reversed by swapping them rather than by a flag.
//
// Each step spans the higher of its two ends, which is what leaves no lip
// between them going either way.
add_ramp :: proc(
	out: ^[dynamic]Brush,
	x0, y0, x1, y1, z0, z1: f32,
	material: Material_ID = .Brick_Alt,
	along_y := true,
	rise: f32 = RAMP_STEP_RISE,
) {
	steps := max(1, int(abs(z1 - z0) / rise + 0.999))
	depth := (along_y ? y1 - y0 : x1 - x0) / f32(steps)

	for i in 0 ..< steps {
		near := z0 + (z1 - z0) * f32(i) / f32(steps)
		far := z0 + (z1 - z0) * f32(i + 1) / f32(steps)
		top := max(near, far)

		if along_y {
			add_floor(out, x0, y0 + f32(i) * depth, x1, y0 + f32(i + 1) * depth, top, material)
		} else {
			add_floor(out, x0 + f32(i) * depth, y0, x0 + f32(i + 1) * depth, y1, top, material)
		}
	}
}

// A wall with a gap you have to walk through, and the lintel over it. `gap0` and
// `gap1` are along the wall's long axis, so a doorway is stated as "this wall,
// open between here and here".
add_doorway :: proc(
	out: ^[dynamic]Brush,
	x0, y0, x1, y1, gap0, gap1: f32,
	material: Material_ID = .Brick,
	height: f32 = WALL_H,
	base: f32 = GROUND_Z,
	along_x := true,
) {
	if along_x {
		append(out, wall(x0, y0, gap0, y1, material, height, base))
		append(out, wall(gap1, y0, x1, y1, material, height, base))
		append(out, box(gap0, y0, base + DOOR_CLEARANCE, gap1, y1, base + height, material))
	} else {
		append(out, wall(x0, y0, x1, gap0, material, height, base))
		append(out, wall(x0, gap1, x1, y1, material, height, base))
		append(out, box(x0, gap0, base + DOOR_CLEARANCE, x1, gap1, base + height, material))
	}
}

// Two crates side by side, the taller one second. The pair is the standard piece
// of cover in this map: the low one is a step, the high one is what you get to
// from it, and together they are the reason to know your jump height.
add_crates :: proc(out: ^[dynamic]Brush, x0, y0, floor, size, low, high: f32, along_x := true) {
	append(out, box(x0, y0, floor, x0 + size, y0 + size, floor + low, .Crate))
	if along_x {
		append(out, box(x0 + size, y0, floor, x0 + 2 * size, y0 + size, floor + high, .Crate))
	} else {
		append(out, box(x0, y0 + size, floor, x0 + size, y0 + 2 * size, floor + high, .Crate))
	}
}

// Rock filling a pocket the player can never reach. Without these the skyline
// behind a five-metre wall is empty sky, and the map reads as a set of corridors
// floating on a plane rather than as something carved out of a hillside.
add_massif :: proc(out: ^[dynamic]Brush, x0, y0, x1, y1: f32, height: f32 = OUTER_H - 2) {
	append(out, wall(x0, y0, x1, y1, .Rock_Alt, height))
}
