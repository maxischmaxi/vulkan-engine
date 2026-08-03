package game

import "core:math"

// The footstep cadence, shared because fog of war moved it onto the wire.
//
// Remote footsteps used to be derived on the client from the positions in the
// snapshot. Once the snapshot stops carrying a pawn nobody can see, that pawn
// also goes silent -- and hearing an enemy you cannot see is half of what a
// tactical shooter is made of. So the server runs this cadence and sends the
// steps as events, and hearing stops depending on seeing.
//
// The client still runs the same procedure for its own player: it predicts its
// own movement, and its own step should not wait for a round trip.

// Metres of ground travel between two footsteps.
FOOTSTEP_STRIDE :: f32(1.9)

// Derived from the run speed rather than written as a number so a movement
// rebalance keeps the guarantee: sneak (0.52x), crouch (0.34x) and scoped
// walk (0.4x) all sit under 0.6x, so slow movement is silent without the
// cadence ever reading a key.
FOOTSTEP_MIN_SPEED :: WALK_SPEED * 0.6

// A bot's wander speed. It sits under FOOTSTEP_MIN_SPEED, which is why bots
// need a threshold of their own rather than the human one -- with that one
// they would be completely silent, and a silent bot is an unfair bot.
BOT_WALK_SPEED :: f32(3.2)
#assert(BOT_WALK_SPEED < FOOTSTEP_MIN_SPEED)

// The threshold a pawn's steps are measured against.
footstep_min_speed :: proc(is_bot: bool) -> f32 {
	return is_bot ? BOT_WALK_SPEED * 0.6 : FOOTSTEP_MIN_SPEED
}

// Ground covered in one tick past which this was a teleport, not a stride: a
// respawn moves a pawn across the map between two ticks and would otherwise
// bank a step's worth of distance instantly.
//
// Far above anything movement can produce -- MAX_SPEED at 64 Hz is about 1.4 m
// in a tick -- so a real bunny hop never trips it.
FOOTSTEP_TELEPORT :: f32(2.0)

// The speed to measure a pawn's cadence at, derived from where it actually
// ended up rather than from its velocity vector.
//
// Necessary because not everything that moves sets a velocity: the server's
// bots are displaced directly through grid_step_move and their velocity stays
// zero horizontally, so reading the vector would make every bot silent.
footstep_speed :: proc(previous, current: [3]f32, dt: f32) -> f32 {
	if dt <= 0 do return 0
	delta := current - previous
	travelled := horizontal_length(delta)
	if travelled > FOOTSTEP_TELEPORT do return 0
	return travelled / dt
}

@(private = "file")
horizontal_length :: proc(v: [3]f32) -> f32 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// How far a sound of each kind carries. Deliberately generous next to
// VISION_MAX_RANGE: this is the information fog of war is meant to let
// through, and a radius trimmed for bandwidth would quietly make the game deaf
// instead of fair.
// Comfortably past the 18 m at which the audio bank fades a footstep to
// silence (audio_bank.odin), so the filter never cuts one off mid-falloff --
// init_audio warns if that entry ever outgrows this.
FOOTSTEP_HEARING_RANGE :: f32(28)
GUNSHOT_HEARING_RANGE :: f32(90)

// One tick of the cadence. `travelled` is the accumulator the caller keeps per
// pawn; a pawn that is airborne, stopped or moving under the threshold resets
// it, so a step never lands the instant someone starts walking again.
//
// `min_speed` exists for the bots: they wander below a human's sneak speed, so
// the human threshold would keep every one of them silent. Bots do not sneak,
// their gait is simply audible -- see footstep_min_speed.
//
// Pure, so the server's copy and the client's local one cannot drift into
// different rhythms.
footstep_step :: proc(
	travelled: f32,
	horizontal_speed: f32,
	on_ground: bool,
	alive: bool,
	dt: f32,
	min_speed: f32 = FOOTSTEP_MIN_SPEED,
) -> (
	next: f32,
	stepped: bool,
) {
	if !alive || !on_ground || dt <= 0 || horizontal_speed < min_speed {
		return 0, false
	}

	next = travelled + horizontal_speed * dt
	if next >= FOOTSTEP_STRIDE {
		return next - FOOTSTEP_STRIDE, true
	}
	return next, false
}

// Whether a sound made at `source` reaches a listener at `listener`. The server
// filters its sound events with this; it is a plain distance test rather than a
// sight line, which is the whole point.
sound_audible :: proc(listener, source: [3]f32, range: f32) -> bool {
	delta := source - listener
	return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z <= range * range
}
