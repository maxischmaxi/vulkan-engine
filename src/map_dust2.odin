package main

// A stripped-down dust2. Only the layout that matters for movement survives:
// the three lanes out of T-spawn, mid with its doors, catwalk onto A-short,
// and the two bombsites. Everything is an axis-aligned box, so the same data
// serves as both render geometry and collision volumes.
//
//                                  N (+Y)
//   +48  ┌──────────────────────────────────────────────────┐
//        │   B-SITE            CT-SPAWN          A-SITE     │
//   +24  │      │                  │           ╱    │       │
//        │   TUNNELS            MID-TOP    CATWALK  │       │
//     0  │      │              [MID DOORS]     │  LONG A    │
//        │      │              [  XBOX   ]     │    │       │
//   -34  │      └────────┐  ┌──────┴──────┐  ┌─┴────┘       │
//        │             T-SPAWN                             │
//   -50  └──────────────────────────────────────────────────┘
//       -52          -20        0        20              +52

WALL_H :: 5.0 // inner walls, high enough that you cannot see over them
OUTER_H :: 9.0 // map shell
WALL_T :: 0.6 // wall thickness
GROUND_Z :: 0.0 // top of the ground plane

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

// Steps instead of a wedge: axis-aligned boxes cannot slope, and the player's
// 0.45 m step-up makes 0.3 m stairs feel like a ramp anyway.
append_stairs :: proc(
	out: ^[dynamic]Brush,
	x0, y0, x1, y1: f32,
	steps: int,
	step_h: f32,
	material: Material_ID,
	along_y := true,
	reverse := false,
) {
	depth := (along_y ? y1 - y0 : x1 - x0) / f32(steps)

	for i in 0 ..< steps {
		fi := f32(reverse ? steps - 1 - i : i)
		height := step_h * f32(i + 1)

		if along_y {
			append(out, wall(x0, y0 + fi * depth, x1, y0 + (fi + 1) * depth, material, height))
		} else {
			append(out, wall(x0 + fi * depth, y0, x0 + (fi + 1) * depth, y1, material, height))
		}
	}
}

build_dust2 :: proc() -> []Brush {
	b := make([dynamic]Brush, 0, 160)

	// ---------------------------------------------------------------- ground
	append(
		&b,
		Brush {
			min      = {-52, -52, -2},
			max      = {52, 52, GROUND_Z},
			material = u32(Material_ID.Ground),
			faces    = {.PosZ}, // buried on all other sides
		},
	)

	// Indoor flooring laid on top of the ground rather than cut into it: a
	// 6 cm slab is real geometry, so there is no z-fighting to worry about.
	slab :: proc(x0, y0, x1, y1: f32) -> Brush {
		return {
			min = {x0, y0, GROUND_Z},
			max = {x1, y1, GROUND_Z + 0.06},
			material = u32(Material_ID.Floor_Indoor),
			faces = NO_BOTTOM,
		}
	}
	append(&b, slab(-44, -34, -26, 22)) // tunnels
	append(&b, slab(-7, -6, 7, 6)) // mid doors landing
	append(&b, slab(26, -24, 44, -16)) // long doors

	// ----------------------------------------------------------- outer shell
	append(&b, wall(-52, -52, 52, -51, .Rock, OUTER_H))
	append(&b, wall(-52, 51, 52, 52, .Rock, OUTER_H))
	append(&b, wall(-52, -52, -51, 52, .Rock, OUTER_H))
	append(&b, wall(51, -52, 52, 52, .Rock, OUTER_H))

	// --------------------------------------------------------------- T-spawn
	// Room spanning X[-18,18] Y[-50,-34], open north into mid and out to the
	// side lanes.
	append(&b, wall(-18, -34 - WALL_T, -7, -34, .Wall_Main)) // north wall, west of mid
	append(&b, wall(7, -34 - WALL_T, 18, -34, .Wall_Main)) // north wall, east of mid
	append(&b, wall(-18 - WALL_T, -50, -18, -42, .Wall_Alt)) // west wall, south part
	append(&b, wall(18, -50, 18 + WALL_T, -42, .Wall_Alt)) // east wall, south part
	append(&b, wall(-18, -50 - WALL_T, 18, -50, .Wall_Trim)) // back wall

	// spawn platform, purely so the start position reads as a spawn
	append(&b, box(-10, -49, GROUND_Z, 10, -46, GROUND_Z + 0.25, .Brick))

	// ------------------------------------------------- T-spawn -> west lanes
	// Corridor from T-spawn to the tunnel system.
	append(&b, wall(-26, -42 - WALL_T, -18, -42, .Wall_Main)) // south side
	append(&b, wall(-26, -34, -18, -34 + WALL_T, .Wall_Main)) // north side

	// ------------------------------------------------- T-spawn -> long A
	append(&b, wall(18, -42 - WALL_T, 26, -42, .Wall_Main))
	append(&b, wall(18, -34, 26, -34 + WALL_T, .Wall_Main))

	// --------------------------------------------------------------- tunnels
	// Vertical corridor X[-44,-26] running north to B.
	append(&b, wall(-44 - WALL_T, -42, -44, 22, .Wall_Alt)) // west wall
	append(&b, wall(-26, -34, -26 + WALL_T, 10, .Wall_Alt)) // east wall, lower part
	append(&b, wall(-26, 14, -26 + WALL_T, 24, .Wall_Alt)) // east wall, upper part
	append(&b, wall(-44, -42 - WALL_T, -26, -42, .Wall_Trim)) // south cap

	// upper tunnel steps up toward B
	append_stairs(&b, -42, 4, -28, 10, 5, 0.3, .Brick_Alt)
	append(&b, wall(-42, 10, -28, 22, .Brick_Alt, 1.5)) // upper tunnel floor

	// tunnel mouth into B site
	append(&b, wall(-44, 22, -34, 22 + WALL_T, .Wall_Main, WALL_H, GROUND_Z + 1.5))

	// ---------------------------------------------------------------- B-site
	// X[-48,-18] Y[24,48]
	append(&b, wall(-48, 48, -18, 48 + WALL_T, .Wall_Main)) // north
	append(&b, wall(-18, 24, -18 + WALL_T, 48, .Wall_Main)) // east, toward CT
	append(&b, wall(-26 + WALL_T, 24, -18, 24 + WALL_T, .Wall_Trim)) // south lip

	// back platform, reached by stairs from the site floor
	append(&b, box(-48, 40, GROUND_Z, -36, 48, GROUND_Z + 1.8, .Brick))
	append_stairs(&b, -36, 40, -33, 48, 6, 0.3, .Brick, along_y = false)

	// crates on site
	append(&b, box(-32, 30, GROUND_Z, -30, 32, GROUND_Z + 1.2, .Crate))
	append(&b, box(-30, 30, GROUND_Z, -28, 32, GROUND_Z + 2.2, .Crate))
	append(&b, box(-24, 34, GROUND_Z, -22, 36, GROUND_Z + 1.2, .Crate))

	// ------------------------------------------------------------------- mid
	// The long central lane X[-7,7] from T-spawn up to CT.
	append(&b, wall(-7 - WALL_T, -34, -7, -8, .Wall_Trim)) // west wall, south of doors
	append(&b, wall(7, -34, 7 + WALL_T, -8, .Wall_Trim)) // east wall, south of doors
	append(&b, wall(-7 - WALL_T, 8, -7, 28, .Wall_Trim)) // west wall, north of doors
	append(&b, wall(7, 8, 7 + WALL_T, 10, .Wall_Trim)) // east wall, up to catwalk
	append(&b, wall(7, 24, 7 + WALL_T, 28, .Wall_Trim)) // east wall, north of catwalk

	// mid doors: two jambs leaving a gap you have to walk through
	append(&b, wall(-7, -1, -2.2, -1 + WALL_T, .Brick))
	append(&b, wall(2.2, -1, 7, -1 + WALL_T, .Brick))
	// lintel above the gap, so it reads as a doorway
	append(&b, box(-2.2, -1, GROUND_Z + 2.6, 2.2, -1 + WALL_T, GROUND_Z + WALL_H, .Brick))

	// xbox
	append(&b, box(-1.6, -12, GROUND_Z, 1.6, -8.8, GROUND_Z + 1.3, .Crate))

	// mid opens into CT spawn
	append(&b, wall(-7, 28, -2, 28 + WALL_T, .Wall_Main))

	// --------------------------------------------------------------- catwalk
	// Raised walkway out of mid that turns north onto A-short. It must not run
	// straight east -- long A is on the far side of that wall, and the two lanes
	// stay separate all the way to the site.
	append_stairs(&b, 7, 10, 12, 14, 5, 0.32, .Brick_Alt, along_y = false)
	append(&b, box(12, 10, GROUND_Z, 20, 14, GROUND_Z + 1.6, .Brick_Alt))
	append(&b, box(15, 14, GROUND_Z, 20, 24, GROUND_Z + 1.6, .Brick_Alt)) // north leg onto the site
	append(&b, wall(12, 10 - WALL_T, 20, 10, .Wall_Alt, 3.4, GROUND_Z + 1.6)) // south rail
	append(&b, wall(12, 14, 15, 14 + WALL_T, .Wall_Alt, 3.4, GROUND_Z + 1.6)) // corner rail
	append(&b, wall(15 - WALL_T, 14, 15, 24, .Wall_Alt, 3.4, GROUND_Z + 1.6)) // west rail

	// ---------------------------------------------------------------- long A
	// Lane up the east side X[26,44].
	append(&b, wall(26 - WALL_T, -34, 26, 20, .Wall_Main)) // west wall
	append(&b, wall(44, -34, 44 + WALL_T, 20, .Wall_Main)) // east wall

	// long doors
	append(&b, wall(26, -20, 31.5, -20 + WALL_T, .Brick))
	append(&b, wall(36.5, -20, 44, -20 + WALL_T, .Brick))
	append(&b, box(31.5, -20, GROUND_Z + 2.6, 36.5, -20 + WALL_T, GROUND_Z + WALL_H, .Brick))

	// cover in long
	append(&b, box(29, -6, GROUND_Z, 31, -4, GROUND_Z + 1.2, .Crate))
	append(&b, box(39, 6, GROUND_Z, 41, 8, GROUND_Z + 1.2, .Crate))

	// ---------------------------------------------------------------- A-site
	// X[20,48] Y[22,48]
	append(&b, wall(20, 48, 48, 48 + WALL_T, .Wall_Main)) // north
	append(&b, wall(20 - WALL_T, 26, 20, 34, .Wall_Alt)) // west, starts above the catwalk mouth
	append(&b, wall(20, 22 - WALL_T, 26, 22, .Wall_Trim)) // south lip east of the catwalk

	// A-ramp: stairs from site floor to the raised platform
	append_stairs(&b, 40, 24, 48, 30, 6, 0.35, .Brick_Alt)
	append(&b, box(40, 30, GROUND_Z, 48, 42, GROUND_Z + 2.1, .Brick_Alt))

	// goose / crates
	append(&b, box(26, 34, GROUND_Z, 28.4, 36.4, GROUND_Z + 1.3, .Crate))
	append(&b, box(28.4, 34, GROUND_Z, 30.8, 36.4, GROUND_Z + 2.4, .Crate))
	append(&b, box(30, 28, GROUND_Z, 32, 30, GROUND_Z + 1.2, .Crate))

	// -------------------------------------------------------------- CT-spawn
	// X[-10,14] Y[34,48], links both sites.
	append(&b, wall(-10, 48, 14, 48 + WALL_T, .Wall_Main)) // north
	append(&b, wall(-10 - WALL_T, 34, -10, 44, .Wall_Alt)) // west, gap at the top toward B
	append(&b, wall(14, 34, 14 + WALL_T, 44, .Wall_Alt)) // east, gap at the top toward A
	append(&b, wall(-2, 34 - WALL_T, 14, 34, .Wall_Trim)) // south, mid enters west of this

	// low cover
	append(&b, box(-4, 40, GROUND_Z, -2, 42, GROUND_Z + 1.1, .Crate))
	append(&b, box(6, 38, GROUND_Z, 8, 40, GROUND_Z + 1.1, .Crate))

	// ------------------------------------------------------- outer scenery
	// Rock masses filling the corners the player can never reach, so the
	// skyline is not a flat wall everywhere.
	append(&b, wall(-51, -51, -44, -42, .Rock_Alt, 7))
	append(&b, wall(44, -51, 51, -42, .Rock_Alt, 6))
	append(&b, wall(-51, 24, -48, 48, .Rock_Alt, 7))
	append(&b, wall(48, -34, 51, 20, .Rock_Alt, 6))
	append(&b, wall(-18, -51, 18, -50 - WALL_T, .Rock_Alt, 7))

	return b[:]
}

// Where the player starts: T-spawn, facing north up mid.
SPAWN_POSITION :: [3]f32{0, -46, GROUND_Z + 0.25}
SPAWN_YAW :: f32(90) // degrees, +Y
