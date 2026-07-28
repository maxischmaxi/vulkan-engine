package game

// The practice range: a walled strip east of the dust2 shell, reachable only
// by teleport. Appended to the dust2 brush list so both binaries bake the same
// world in the same order and prediction stays bit-compatible.
//
// The player shoots from a raised podium at the west end over a hip-high
// counter; bots wander three bands at increasing distance. Nothing but that
// counter stands anywhere in the range: every target must be visible from
// every spot on the podium, so there are no booth walls and no cover. The two
// fences that make this true are both soft -- the practice tick teleports the
// player back into PRACTICE_BOUNDS and clamps each bot to its band, because a
// real wall would block shots and sightlines along with the walking.
//
//        N (+Y)
//   +20 ┌────────────────────────────────────────────┐
//       │                                            │
//    +3 │  ────▐ counter                             │
//       │ podium▐            NEAR    MID     FAR     │
//    -3 │  ────▐                                     │
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

	// The podium and its counter -- deliberately no walls and no cover
	// anywhere beyond this: sightlines to every band corner stay open from
	// every spot the player can stand on.
	add_floor(b, 72, -3, 78.3, 3, PRACTICE_BOOTH_FLOOR, .Brick)
	append(b, wall(78.3, -3, 78.6, 3, .Wall_Trim, PRACTICE_COUNTER_H)) // counter
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
