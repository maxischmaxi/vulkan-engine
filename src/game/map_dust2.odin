package game

// A dust2 you would recognise without mistaking it for the original. Every lane
// the map is known for is here and in the right place relative to the others:
// three ways out of T-spawn, mid split by its doors, catwalk onto A-short, long
// with its pit, the tunnels through to B, and CT-spawn sitting between the two
// sites. The proportions are ours, the shape is theirs.
//
// It is also the test rig for the movement. Nothing here is at an arbitrary
// height: ledges are placed at the three heights that matter, and which one you
// are looking at is the whole question the movement asks.
//
//   up to 1.2 m   walked over or cleared with a plain jump
//   1.4 - 1.8 m   only with a duck at the top of the jump (see AIR_DUCK_LIFT)
//   above 1.8 m   needs a crate under it first
//
//                                     N (+Y)
//   +44  ┌──────────────────────────────────────────────────────────┐
//        │   B SITE  ▒back plat    │  CT SPAWN │        A SITE      │
//   +30  │      ▒big box           │   (2.4)   ╲ramp     ▒plat(3.0) │
//        │           ╲B doors══════╯           │       (1.4)        │
//   +16  │  ══tunnel mouth══     ┌── TOP MID ──┘   ┌──┘             │
//        │                       │    (1.2)        │ ▒short         │
//    0   │  LOWER TUNNELS (0)    │   ╱ramp    CATWALK (1.8)  PIT(0) │
//        │                       │  │              │      LONG A    │
//   -12  │      ╲ramp down       │ MID (0)  ▒xbox  │       (1.2)    │
//        │  UPPER TUNNELS (1.6)  │  │              │        │       │
//   -24  │      ╱ramp up         │  │              │  [LONG DOORS]  │
//        │  OUTSIDE TUNNELS      │[MID DOORS]      │        │       │
//   -36  │  ═════════════════  T SPAWN (0)  ══════════════════      │
//   -50  └──────────────────────────────────────────────────────────┘
//        -48      -38    -28     -16  -6  6      16  24      42   46

build_dust2 :: proc() -> []Brush {
	b := make([dynamic]Brush, 0, 256)

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

	// ----------------------------------------------------------- outer shell
	append(&b, wall(-52, -52, 52, -51, .Rock, OUTER_H))
	append(&b, wall(-52, 51, 52, 52, .Rock, OUTER_H))
	append(&b, wall(-52, -52, -51, 52, .Rock, OUTER_H))
	append(&b, wall(51, -52, 52, 52, .Rock, OUTER_H))

	build_t_spawn(&b)
	build_tunnels(&b)
	build_b_site(&b)
	build_mid(&b)
	build_catwalk(&b)
	build_long(&b)
	build_a_site(&b)
	build_ct_spawn(&b)
	build_scenery(&b)

	return b[:]
}

// --------------------------------------------------------------------- T side

// X[-16,16] Y[-50,-36], with three ways out: west to the tunnels, north up mid,
// east to long. All three leave through gaps in these walls rather than through
// doorways, so the first decision of a round is made at a run.
@(private = "file")
build_t_spawn :: proc(b: ^[dynamic]Brush) {
	append(b, wall(-16, -50 - WALL_T, 16, -50, .Wall_Trim)) // back
	append(b, wall(-16 - WALL_T, -50, -16, -46, .Wall_Alt)) // west, south of the gap
	append(b, wall(-16 - WALL_T, -40, -16, -36, .Wall_Alt)) // west, north of it
	append(b, wall(16, -50, 16 + WALL_T, -46, .Wall_Alt)) // east, south of the gap
	append(b, wall(16, -40, 16 + WALL_T, -36, .Wall_Alt)) // east, north of it
	append(b, wall(-16, -36, -6, -36 + WALL_T, .Wall_Main)) // north, west of mid
	append(b, wall(6, -36, 16, -36 + WALL_T, .Wall_Main)) // north, east of mid

	// spawn platform, purely so the start position reads as a spawn
	append(b, box(-10, -49, GROUND_Z, 10, -46, GROUND_Z + 0.25, .Brick))

	// ------------------------------------------------------- outside tunnels
	// The open ground west of spawn, between T-spawn and the tunnel mouth.
	append(b, wall(-42, -48 - WALL_T, -16, -48, .Wall_Trim)) // south
	append(b, wall(-42 - WALL_T, -48, -42, -36, .Wall_Alt)) // west
	append(b, wall(-42, -36, -38, -36 + WALL_T, .Wall_Main)) // north, west of the mouth
	append(b, wall(-28, -36, -16, -36 + WALL_T, .Wall_Main)) // north, east of it
	append(b, box(-31, -45, GROUND_Z, -28, -42, GROUND_Z + 1.2, .Crate))

	// ---------------------------------------------------------- outside long
	// The same on the east side, feeding the long corridor.
	append(b, wall(16, -48 - WALL_T, 42, -48, .Wall_Trim)) // south
	append(b, wall(42, -48, 42 + WALL_T, -36, .Wall_Main)) // east
	append(b, wall(16, -36, 24, -36 + WALL_T, .Wall_Main)) // north, west of long
	append(b, box(28, -45, GROUND_Z, 31, -42, GROUND_Z + 1.2, .Crate))
}

// ---------------------------------------------------------------- the tunnels

// Upper tunnels climb out of outside-tunnels, run level, then drop the whole way
// back down into lower tunnels -- the piece of dust2 that is genuinely a tunnel
// rather than a corridor, so it gets a roof and lives in the dark.
@(private = "file")
build_tunnels :: proc(b: ^[dynamic]Brush) {
	// ---------------------------------------------------------- upper tunnel
	// X[-38,-28], climbing to 1.6 and back down to the floor by Y = -12.
	add_ramp(b, -38, -36, -28, -29, GROUND_Z, 1.6)
	add_floor(b, -38, -29, -28, -23, 1.6)
	add_ramp(b, -38, -23, -28, -12, 1.6, GROUND_Z)

	append(b, wall(-38 - WALL_T, -36, -38, -12, .Wall_Alt, 6)) // west
	append(b, wall(-28, -36, -28 + WALL_T, -12, .Wall_Alt, 6)) // east
	add_ceiling(b, -38, -36, -28, -12, 4.8)

	// ---------------------------------------------------------- lower tunnel
	// The wide hall the ramp lands in, X[-46,-28] Y[-12,10].
	add_slab(b, -46, -12, -28, 10)
	append(b, wall(-46 - WALL_T, -12, -46, 10, .Wall_Alt, 6)) // west
	append(b, wall(-28, -12, -28 + WALL_T, 10, .Wall_Alt, 6)) // east
	append(b, wall(-46, -12, -38, -12 + WALL_T, .Wall_Trim, 6)) // south, west of the mouth
	append(b, wall(-46, 10 - WALL_T, -40, 10, .Wall_Trim, 6)) // north, west of the exit
	append(b, wall(-30, 10 - WALL_T, -28, 10, .Wall_Trim, 6)) // north, east of it
	add_ceiling(b, -46, -12, -28, 10, 4.6)

	// Chest-high in a dark tunnel: a duck behind it is real cover, and getting
	// on top of it is a crouch-jump.
	append(b, box(-35, -6, GROUND_Z, -32, -3, GROUND_Z + 1.6, .Crate))

	// ------------------------------------------------------------ B tunnel mouth
	// The last stretch before the site opens up, still roofed.
	add_slab(b, -40, 10, -30, 16)
	append(b, wall(-40 - WALL_T, 10, -40, 16, .Wall_Main, 6))
	append(b, wall(-30, 10, -30 + WALL_T, 16, .Wall_Main, 6))
	add_ceiling(b, -40, 10, -30, 16, 4.6)
}

// ---------------------------------------------------------------------- B site

// X[-48,-20] Y[16,44]. Two ways in -- the tunnel from the south and the doors
// from CT in the north-east corner -- and a back platform that watches both.
@(private = "file")
build_b_site :: proc(b: ^[dynamic]Brush) {
	append(b, wall(-48, 44, -20, 44 + WALL_T, .Wall_Main)) // north
	append(b, wall(-48 - WALL_T, 16, -48, 44, .Wall_Main)) // west
	append(b, wall(-48, 16 - WALL_T, -40, 16, .Wall_Trim)) // south, west of the mouth
	append(b, wall(-30, 16 - WALL_T, -20, 16, .Wall_Trim)) // south, east of it
	append(b, wall(-20, 16, -20 + WALL_T, 38, .Wall_Alt)) // east, up to the doors

	// back platform and the steps onto it
	add_floor(b, -48, 34, -38, 44, 1.8, .Brick)
	add_ramp(b, -38, 38, -34.4, 44, 1.8, GROUND_Z, .Brick, along_y = false)

	// the double stack: the low one is a step, the high one is the angle
	add_crates(b, -36, 26, GROUND_Z, 3, 1.6, 2.6)
	append(b, box(-27, 36, GROUND_Z, -24, 39, GROUND_Z + 1.2, .Crate))
	append(b, box(-45, 20, GROUND_Z, -42, 23, GROUND_Z + 1.2, .Crate))

	// ------------------------------------------------------ B doors, from CT
	// A short corridor that climbs the 2.4 m between the site and CT-spawn.
	append(b, wall(-20, 38 - WALL_T, -14, 38, .Wall_Alt, 7)) // south
	append(b, wall(-20, 44, -14, 44 + WALL_T, .Wall_Alt, 7)) // north
	add_doorway(b, -19, 38, -18.4, 44, 40, 42.4, .Brick, along_x = false)
	add_ramp(b, -18, 38, -14, 44, GROUND_Z, 2.4, .Brick, along_y = false)
}

// ------------------------------------------------------------------------ mid

// The long central lane, X[-6,6] from T-spawn all the way to CT. It climbs 2.4 m
// over its length, which is what makes holding it from the north an advantage
// worth the exposure.
@(private = "file")
build_mid :: proc(b: ^[dynamic]Brush) {
	append(b, wall(-6 - WALL_T, -36, -6, 34, .Wall_Trim, 7)) // west, unbroken
	append(b, wall(6, -36, 6 + WALL_T, 4, .Wall_Trim, 7)) // east, south of catwalk
	append(b, wall(6, 10, 6 + WALL_T, 34, .Wall_Trim, 7)) // east, north of it

	// mid doors, the one place the whole lane narrows to a gap
	add_doorway(b, -6, -10, 6, -10 + WALL_T, -2, 2)

	// The xbox. Waist height on the radar and a crouch-jump in practice: the
	// angle onto catwalk from up here is the reason to know the difference.
	append(b, box(2.5, -2, GROUND_Z, 5.5, 1, GROUND_Z + 1.6, .Crate))

	// the climb to top mid, then on up into CT-spawn
	add_ramp(b, -6, 12, 6, 20, GROUND_Z, 1.2)
	add_floor(b, -6, 20, 6, 30, 1.2)
	// Full width, so the two metres either side of CT's doorway are floor rather
	// than a trench beside the steps.
	add_ramp(b, -6, 30, 6, 34, 1.2, 2.4, .Brick)

	// low cover on top mid, so it is not a flat shooting gallery
	append(b, box(-4, 22, 1.2, -1.6, 24.4, 1.2 + 1.2, .Crate))
}

// -------------------------------------------------------------------- catwalk

// Up out of mid, then north onto A-short. It must not run straight east -- long
// is on the far side of that wall, and the two lanes stay separate all the way
// to the site.
@(private = "file")
build_catwalk :: proc(b: ^[dynamic]Brush) {
	add_ramp(b, 6, 4, 10, 10, GROUND_Z, 1.8, .Brick_Alt, along_y = false)
	add_floor(b, 10, 4, 18, 10, 1.8, .Brick_Alt)
	add_floor(b, 13, 10, 18, 20, 1.8, .Brick_Alt) // the leg onto the site

	// Rails rather than walls: they stop at 5 m so the drop into mid stays
	// visible from up here, which is the whole point of the position.
	append(b, wall(10, 4 - WALL_T, 18, 4, .Wall_Alt, 3.2, 1.8)) // south
	append(b, wall(18, 4, 18 + WALL_T, 20, .Wall_Alt, 3.2, 1.8)) // east
	// The west side goes down to the ground rather than starting at the deck:
	// there is nothing to see over it, and a rail on stilts leaves a slot beside
	// the leg deep enough to drop into.
	append(b, wall(13 - WALL_T, 10, 13, 20, .Wall_Alt, 5))
	append(b, wall(10, 10, 13, 10 + WALL_T, .Wall_Alt, 3.2, 1.8)) // the corner
}

// ------------------------------------------------------------------- long A

// The east lane, X[24,42], climbing 1.2 m out of outside-long and running the
// length of the map to the site. The pit is the part that matters: a metre and a
// bit below the lane, easy to drop into and a plain jump to get back out of.
@(private = "file")
build_long :: proc(b: ^[dynamic]Brush) {
	add_ramp(b, 24, -36, 42, -30, GROUND_Z, 1.2)

	// The lane floor, cut around the pit rather than laid over it.
	add_floor(b, 31, -30, 42, 14, 1.2)
	add_floor(b, 24, -30, 31, 0, 1.2)
	add_floor(b, 24, 12, 31, 14, 1.2)

	// The corner into the site. Two centimetres short of a step, so the turn is
	// taken at a run rather than climbed.
	add_floor(b, 24, 14, 42, 20, 1.4)

	append(b, wall(24 - WALL_T, -36, 24, 20, .Wall_Main, 7)) // west
	append(b, wall(42, -36, 42 + WALL_T, 20, .Wall_Main, 7)) // east

	add_doorway(b, 24, -24, 42, -24 + WALL_T, 30, 34, .Brick, base = 1.2)

	append(b, box(25, -14, 1.2, 28, -11, 1.2 + 1.2, .Crate))
	append(b, box(38, -4, 1.2, 41, -1, 1.2 + 1.2, .Crate))

	// ------------------------------------------------------------------ pit
	// Ground level, so the lip back up onto long is 1.2 m: a jump, and a
	// crouch-jump if you are carrying no speed into it.
	add_slab(b, 24, 0, 31, 12)
	append(b, box(25, 2, GROUND_Z, 27, 4, GROUND_Z + 1.0, .Crate))
}

// ---------------------------------------------------------------------- A site

// X[14,46] Y[20,44], a metre and a half up. Three ways in: short from the
// catwalk, long from the south-east, and the ramp down out of CT.
@(private = "file")
build_a_site :: proc(b: ^[dynamic]Brush) {
	add_floor(b, 14, 20, 46, 44, 1.4)

	append(b, wall(14, 44, 46, 44 + WALL_T, .Wall_Main, 7, 1.4)) // north
	append(b, wall(46, 20, 46 + WALL_T, 44, .Wall_Main, 7, 1.4)) // east
	append(b, wall(18, 20 - WALL_T, 24, 20, .Wall_Trim, 7, 1.4)) // south, between short and long
	append(b, wall(42, 20 - WALL_T, 46, 20, .Wall_Trim, 7, 1.4)) // south, east of long
	append(b, wall(14 - WALL_T, 20, 14, 36, .Wall_Alt, 7, 1.4)) // west, below the ramp

	// The platform, and the steps up onto it from the middle of the site.
	add_floor(b, 34, 30, 46, 42, 3.0, .Brick_Alt)
	add_ramp(b, 30, 32, 34, 40, 1.4, 3.0, .Brick_Alt, along_y = false)

	// goose, where short lets out
	add_crates(b, 16, 22, 1.4, 3, 1.2, 2.4)

	// Site cover at the two heights that ask different things of you.
	append(b, box(26, 26, 1.4, 28, 28, 1.4 + 1.6, .Crate)) // crouch-jump
	append(b, box(30, 22, 1.4, 32, 24, 1.4 + 1.2, .Crate)) // plain jump

	// ninja: the pocket behind the platform, reachable only from the site floor
	append(b, box(34, 42, 1.4, 46, 44, 1.4 + 1.2, .Crate))
}

// ------------------------------------------------------------------- CT spawn

// X[-14,14] Y[34,48], the high ground between the two sites, with a way down to
// each and a way down to mid.
@(private = "file")
build_ct_spawn :: proc(b: ^[dynamic]Brush) {
	add_floor(b, -14, 34, 14, 48, 2.4, .Brick)

	append(b, wall(-14, 48, 14, 48 + WALL_T, .Wall_Main, 6, 2.4)) // north
	append(b, wall(-14 - WALL_T, 34, -14, 38, .Wall_Alt, 6, 2.4)) // west, south of B doors
	append(b, wall(-14 - WALL_T, 44, -14, 48, .Wall_Alt, 6, 2.4)) // west, north of them
	append(b, wall(14, 34, 14 + WALL_T, 36, .Wall_Alt, 6, 2.4)) // east, south of the ramp
	append(b, wall(14, 44, 14 + WALL_T, 48, .Wall_Alt, 6, 2.4)) // east, north of it
	append(b, wall(-14, 34 - WALL_T, -4, 34, .Wall_Trim, 6, 2.4)) // south, west of mid
	append(b, wall(4, 34 - WALL_T, 14, 34, .Wall_Trim, 6, 2.4)) // south, east of mid

	append(b, box(-8, 40, 2.4, -6, 42, 2.4 + 1.1, .Crate))
	append(b, box(8, 38, 2.4, 10, 40, 2.4 + 1.1, .Crate))

	// A-ramp: the drop out of spawn onto the site, and the fastest way to A.
	add_ramp(b, 14, 36, 22, 44, 2.4, 1.4, .Brick_Alt, along_y = false)
}

// ------------------------------------------------------------------- scenery

// The rock the map is cut out of. Every one of these fills a pocket no route
// reaches; without them a five-metre wall has open sky behind it and the lanes
// read as corridors laid on a plane.
@(private = "file")
build_scenery :: proc(b: ^[dynamic]Brush) {
	add_massif(b, 6.6, -35.4, 23.4, 3.4) // between mid and long
	add_massif(b, 18.6, 3.4, 23.4, 19.4) // between catwalk and long
	add_massif(b, 6.6, 10, 12.4, 19.4) // the pocket west of the catwalk leg
	add_massif(b, 6.6, 19.4, 13.4, 34) // between mid and the A-site wall
	add_massif(b, -15.4, -35.4, -6.6, -12.6) // between T-spawn and mid
	add_massif(b, -27.4, -12.6, -6.6, 15.4) // the mass between tunnels and mid
	add_massif(b, -27.4, -35.4, -15.4, -12.6) // east of the upper tunnel
	add_massif(b, -42, -35.4, -38.6, -12.6) // west of it
	add_massif(b, -19.4, 16.6, -6.6, 33.4) // between B and mid
	add_massif(b, 42.6, -35.4, 46, 19.4) // east of long

	// Corners of the shell, so the skyline has a shape.
	add_massif(b, -51, -51, -42.6, -48.6, OUTER_H - 3)
	add_massif(b, 42.6, -51, 51, -48.6, OUTER_H - 3)
	add_massif(b, -51, 44.6, 51, 51, OUTER_H - 3)
	add_massif(b, 46.6, 13.4, 51, 44.6, OUTER_H - 3)
	add_massif(b, -51, -12, -46.6, 44.6, OUTER_H - 3)
}

// Where the player starts: T-spawn, facing north up mid.
SPAWN_POSITION :: [3]f32{0, -47, GROUND_Z + 0.25}
SPAWN_YAW :: f32(90) // degrees, +Y

// Where bots may appear, one rectangle per room with the floor it stands on.
//
// Sampling the whole map instead -- which is what this used to do -- puts them
// on tunnel roofs: the probe comes down from the sky and lands on the first
// surface it meets, and a roofed map has plenty of those. A room list is also
// the only thing that keeps them spread across the routes rather than pooled
// wherever the open ground happens to be.
Spawn_Area :: struct {
	min, max: [2]f32,
	floor:    f32,
}

MAP_SPAWN_AREAS := []Spawn_Area {
	{{-14, -48}, {14, -38}, GROUND_Z}, // T spawn
	{{-40, -46}, {-18, -38}, GROUND_Z}, // outside tunnels
	{{-37, -29}, {-29, -23}, 1.6}, // upper tunnels, the level stretch between the ramps
	{{-44, -10}, {-30, 8}, GROUND_Z}, // lower tunnels
	{{-46, 18}, {-22, 42}, GROUND_Z}, // B site
	{{-4, -34}, {4, -12}, GROUND_Z}, // mid, south of the doors
	{{-4, 0}, {4, 10}, GROUND_Z}, // mid, north of them
	{{-4, 21}, {4, 29}, 1.2}, // top mid
	{{-12, 36}, {12, 46}, 2.4}, // CT spawn
	{{18, -46}, {40, -38}, GROUND_Z}, // outside long
	{{26, -28}, {40, -26}, 1.2}, // long, T side of the doors
	{{32, -8}, {40, 12}, 1.2}, // long, north of them
	{{11, 6}, {17, 18}, 1.8}, // catwalk
	{{16, 22}, {44, 42}, 1.4}, // A site
}
