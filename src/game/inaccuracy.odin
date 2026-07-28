package game

import "../physics"
import "core:math"
import "core:math/rand"

// Random spread on top of the deterministic spray: moving feet and air time
// cost accuracy. The draw happens on the server's rng -- the one part of a
// shot a modified client cannot precompute, which caps what any aimbot can
// hit on the move. Standing still costs nothing, so the spray pattern stays
// learnable and shot 0 of a planted burst is still a laser.

// Crouching steadies the move penalty; hanging in the air it buys nothing.
CROUCH_INACC_SCALE :: 0.6

// Deep sprays stop opening the cone here: the pattern already wanders, the
// bloom on top only needs to make marathon holds pay.
FIRE_INACC_CAP_SHOTS :: 10.0

// The cone half-angle in degrees a shot deserves, from stance and burst depth.
// Pure and shared: the client sizes its crosshair from it, the server sizes
// the draw. Depth 0 adds nothing -- the first shot stays exact.
inaccuracy_degrees :: proc(weapon: Weapon, p: Pawn, zoom_held: bool, spray_progress: f32) -> f32 {
	frac := clamp(physics.horizontal_speed(p.body.velocity) / WALK_SPEED, 0, 1)
	inacc := weapon.inacc_move * frac * frac
	if p.crouching do inacc *= CROUCH_INACC_SCALE
	if !p.body.on_ground do inacc += weapon.inacc_air
	if weapon.zoom_fov > 0 && !zoom_held do inacc += weapon.inacc_unscoped
	inacc += weapon.inacc_fire * min(spray_progress, FIRE_INACC_CAP_SHOTS)
	return inacc
}

// A uniform draw inside the cone, as {d_yaw, d_pitch} degrees. Two draws per
// pellet in a fixed order, so a seeded generator replays exactly -- and a
// zero cone draws nothing at all, which keeps planted fire off the rng.
inaccuracy_offset :: proc(rng: rand.Generator, inacc_deg: f32) -> [2]f32 {
	if inacc_deg <= 0 do return {0, 0}
	r := inacc_deg * math.sqrt(rand.float32(rng))
	theta := rand.float32(rng) * math.TAU
	return {r * math.cos(theta), r * math.sin(theta)}
}
