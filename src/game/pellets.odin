package game

import "core:math"

// The shotgun's pellet pattern: a fixed rosette, the same offsets every shot,
// counter-strike 1.6 style. Deterministic by construction -- no rng, so the
// client's cosmetic mirror and the server agree without shared state, and the
// pattern is something a player can learn.

MAX_PELLETS :: 9
NOVA_PELLETS :: 9
#assert(NOVA_PELLETS <= MAX_PELLETS)

// Unit-disc offsets {right, up}: the center, four on the axes at half radius,
// four on the diagonals at full radius.
@(rodata)
PELLET_OFFSETS := [MAX_PELLETS][2]f32 {
	{0, 0},
	{0.5, 0},
	{0, 0.5},
	{-0.5, 0},
	{0, -0.5},
	{0.70710678, 0.70710678},
	{-0.70710678, 0.70710678},
	{-0.70710678, -0.70710678},
	{0.70710678, -0.70710678},
}

// The direction pellet `index` flies, given the shooter's view angles and the
// weapon's spread (tangent of the cone half-angle).
pellet_dir :: proc(yaw, pitch: f32, index: int, spread: f32) -> [3]f32 {
	forward := view_forward(yaw, pitch)
	// Index 0 is the center pellet: forward untouched, so single-ray weapons
	// trace bit-identically to the pre-pellet code.
	if index == 0 || spread <= 0 do return forward

	o := PELLET_OFFSETS[index]
	right := yaw_right(yaw)
	up := view_up(yaw, pitch)
	d := forward + (right * o.x + up * o.y) * spread
	// The basis is orthonormal, so the length is known in closed form.
	return d / math.sqrt(1 + spread * spread * (o.x * o.x + o.y * o.y))
}
