package game

// The bomb's shared vocabulary and pure rules. The state machine itself runs
// on the server (server/bomb.odin); this file holds what both ends must agree
// on: state names, timings, site volumes, the explosion falloff and the
// progress steppers -- so the client's bars and muzzle mirror exactly what
// the server decides.

Bomb_State :: enum u8 {
	None, // no bomb in play (TDM, warmup, pre-round)
	Carried,
	Dropped,
	Planted,
	Defused,
	Exploded,
}

// Pawn-id sentinel on the wire: no carrier / no defuser.
BOMB_NO_PAWN :: u8(0xFF)

BOMB_PLANT_TIME :: 3.2
BOMB_DEFUSE_TIME :: 10.0
BOMB_FUSE :: 40.0
BOMB_PICKUP_RANGE :: 1.2 // horizontal metres to a dropped bomb
BOMB_DEFUSE_RANGE :: 1.6 // horizontal metres to a planted bomb
BOMB_DAMAGE_MAX :: 500 // at the plant spot; falls off linearly
BOMB_DAMAGE_RADIUS :: 14.0
BOMB_ARMOR_PEN :: 0.5

// Whether the bomb lies somewhere in the world -- exactly the states whose
// snapshot block carries a position.
bomb_has_position :: proc(s: Bomb_State) -> bool {
	return s == .Dropped || s == .Planted
}

// A plantable area: a rectangle on a known floor, tighter than the room that
// contains it so "in site" means on the pad, not near it.
Bombsite :: struct {
	min, max: [2]f32,
	floor:    f32,
	tag:      u8, // 'A' or 'B', display only
}

// Which site a position is inside, -1 for none. The z band is generous
// upward (a crate on the pad still counts) and tight downward.
bomb_site_at :: proc(sites: []Bombsite, position: [3]f32) -> int {
	for site, i in sites {
		if position.x < site.min.x || position.x > site.max.x do continue
		if position.y < site.min.y || position.y > site.max.y do continue
		if position.z < site.floor - 1 || position.z > site.floor + 3 do continue
		return i
	}
	return -1
}

bomb_explosion_damage :: proc(dist: f32) -> int {
	if dist >= BOMB_DAMAGE_RADIUS do return 0
	return int(f32(BOMB_DAMAGE_MAX) * (1 - dist / BOMB_DAMAGE_RADIUS))
}

// The progress steppers: accumulate while engaged, reset the moment the
// conditions break. Pure so the timing rules are testable and both ends
// derive bars from the same arithmetic.
bomb_plant_step :: proc(progress: f32, engaged: bool, dt: f32) -> (next: f32, done: bool) {
	if !engaged do return 0, false
	next = progress + dt
	return next, next >= BOMB_PLANT_TIME
}

bomb_defuse_step :: proc(progress: f32, engaged: bool, dt: f32) -> (next: f32, done: bool) {
	if !engaged do return 0, false
	next = progress + dt
	return next, next >= BOMB_DEFUSE_TIME
}
