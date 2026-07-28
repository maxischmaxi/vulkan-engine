package game

// The practice range: a walled strip east of the dust2 shell, reachable only
// by teleport. Appended to the dust2 brush list so both binaries bake the same
// world in the same order and prediction stays bit-compatible.
//
// The player shoots from a raised booth at the west end over a hip-high
// counter; bots wander three bands at increasing distance. The booth is not
// escape-proof geometry -- the practice tick teleports the player back when
// they leave PRACTICE_BOUNDS, so the counter only has to read as a barrier.
//
//        N (+Y)
//   +20 ┌────────────────────────────────────────────┐
//       │                                            │
//    +3 │ ┌──────┐                                   │
//       │ │BOOTH ▐ counter   NEAR    MID     FAR     │
//    -3 │ └──────┘          ▒crates ▒       ▒        │
//       │                                            │
//   -20 └────────────────────────────────────────────┘
//       70   72  78.6  82  90  92  100 102  108    110

PRACTICE_FLOOR_T :: 0.5 // thin enough to stay off the minimap
PRACTICE_WALL_H :: 3.0
PRACTICE_BOOTH_FLOOR :: 0.3 // raised so shots over the counter reach feet
PRACTICE_COUNTER_H :: 1.15 // hip height: standing eye clears it, crouched does not

// Booth interior, with margin. The practice tick teleports the player back to
// the spawn whenever they leave this box; it is the actual confinement.
Practice_Bounds :: struct {
	min, max: [3]f32,
}

PRACTICE_BOUNDS :: Practice_Bounds {
	min = {71.5, -3.5, -1},
	max = {78.9, 3.5, 4},
}

// Back of the booth, facing +X down the range.
PRACTICE_PLAYER_SPAWN :: [3]f32{76.8, 0, PRACTICE_BOOTH_FLOOR + 0.26}
PRACTICE_SPAWN_YAW :: f32(0) // degrees, +X

// One band per distance so near/mid/far stay populated no matter where the
// wander takes the bots between respawns. Deliberately NOT part of
// MAP_SPAWN_AREAS: that list feeds live respawns and the benchmark.
PRACTICE_BOT_AREAS := []Spawn_Area {
	{{82, -16}, {90, 16}, GROUND_Z}, // near
	{{92, -16}, {100, 16}, GROUND_Z}, // mid
	{{102, -16}, {108, 16}, GROUND_Z}, // far
}

build_practice_range :: proc(b: ^[dynamic]Brush) {
	// floor and perimeter; the side walls sit between the north/south ones so
	// no two brushes overlap
	append(b, wall(70, -20, 110, 20, .Ground, PRACTICE_FLOOR_T, -PRACTICE_FLOOR_T))
	append(b, wall(70, -20, 110, -19.4, .Rock, PRACTICE_WALL_H)) // south
	append(b, wall(70, 19.4, 110, 20, .Rock, PRACTICE_WALL_H)) // north
	append(b, wall(70, -19.4, 70.6, 19.4, .Rock, PRACTICE_WALL_H)) // west
	append(b, wall(109.4, -19.4, 110, 19.4, .Rock, PRACTICE_WALL_H)) // east

	// the booth: raised floor, full-height back and sides, hip-high counter
	add_floor(b, 72, -3, 78.3, 3, PRACTICE_BOOTH_FLOOR, .Brick)
	append(b, wall(71.4, -3, 72, 3, .Wall_Main, PRACTICE_WALL_H)) // back
	append(b, wall(71.4, -3.6, 78.6, -3, .Wall_Main, PRACTICE_WALL_H)) // south
	append(b, wall(71.4, 3, 78.6, 3.6, .Wall_Main, PRACTICE_WALL_H)) // north
	append(b, wall(78.3, -3, 78.6, 3, .Wall_Trim, PRACTICE_COUNTER_H)) // counter

	// cover between the bands, so the range is not a flat gallery
	append(b, box(90.5, -8, GROUND_Z, 92, -6.5, GROUND_Z + 1.2, .Crate))
	append(b, box(100.4, 4, GROUND_Z, 101.9, 5.5, GROUND_Z + 1.6, .Crate))
	append(b, box(95, 10, GROUND_Z, 96.5, 11.5, GROUND_Z + 1.0, .Crate))
}

practice_inside_bounds :: proc(p: [3]f32) -> bool {
	return(
		p.x >= PRACTICE_BOUNDS.min.x &&
		p.x <= PRACTICE_BOUNDS.max.x &&
		p.y >= PRACTICE_BOUNDS.min.y &&
		p.y <= PRACTICE_BOUNDS.max.y &&
		p.z >= PRACTICE_BOUNDS.min.z &&
		p.z <= PRACTICE_BOUNDS.max.z \
	)
}
