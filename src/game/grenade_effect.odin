package game

import "core:math/linalg"

// What each grenade does when it goes off, as rules over plain numbers. The
// server applies them because it owns the pawn list; everything decidable
// without one is decided here, where it can be tested.

// ------------------------------------------------------------------ he

// Counter-strike's grenade, roughly: lethal to a hurt player at the centre,
// survivable at the edge, and it does not go through walls.
HE_MAX_DAMAGE :: 98
HE_RADIUS :: f32(8.9) // 350 units

// A vest takes a real bite out of a blast, more than it takes out of a rifle
// round -- which is what makes armour worth buying against a nade stack.
HE_ARMOR_PEN :: f32(0.3)

// Self-damage is full: a badly thrown grenade at your own feet should hurt as
// much as it hurts anyone else. Teammates take it too, matching the bullets --
// nothing else in this game checks teams before doing damage.
he_damage_at :: proc(distance: f32) -> int {
	return explosion_damage(HE_MAX_DAMAGE, distance, HE_RADIUS)
}

// ------------------------------------------------------------------ flash

// Seconds of white at the worst possible angle and distance, and the least a
// flash that affects you at all can do. Between the two it scales with how
// much of it you were looking at.
FLASH_MAX_DURATION :: f32(3.4)
FLASH_MIN_DURATION :: f32(0.3)

// Past this the pop is just a noise.
FLASH_RADIUS :: f32(13)

// Facing straight at it is 1, dead behind is -1. Everything at or below this
// cosine counts as fully behind you and gets the minimum -- a flash over your
// shoulder still robs a moment of vision.
//
// 120 degrees rather than 90: the eye catches a flash somewhat past its
// shoulder, and a hard cutoff exactly at the edge of view would make a metre
// of strafe the difference between blind and untouched.
FLASH_BEHIND_COS :: f32(-0.5)

// How long a pawn is blinded. Zero means unaffected, which is the answer
// whenever the world is in the way -- a flash behind a wall does nothing at
// all, and that is the whole reason it is worth learning to line one up.
//
// `forward` is the pawn's view direction; `blocked` comes from the caller's
// sight test, so this stays free of the world.
flash_duration :: proc(eye, forward, flash_position: [3]f32, blocked: bool) -> f32 {
	if blocked do return 0

	delta := flash_position - eye
	distance := linalg.length(delta)
	if distance >= FLASH_RADIUS do return 0
	if distance < 0.001 do return FLASH_MAX_DURATION

	to_flash := delta / distance
	facing := linalg.dot(linalg.normalize(forward), to_flash)
	if facing <= FLASH_BEHIND_COS do return FLASH_MIN_DURATION

	// Two independent falloffs: how directly you looked at it, and how close
	// it went off. Multiplied rather than averaged, so a distant flash you
	// stared straight at and a close one at the edge of vision both come out
	// mild, and only the close one you looked at is blinding.
	//
	// Both linear. An earlier version squared the angle term, which sounded
	// right and made anything past about 45 degrees collapse to the minimum --
	// a flash you catch side-on has to cost real time, or nobody would ever
	// need to turn away from one.
	aim := (facing - FLASH_BEHIND_COS) / (1 - FLASH_BEHIND_COS)
	range := 1 - distance / FLASH_RADIUS
	scale := aim * range

	return max(FLASH_MAX_DURATION * scale, FLASH_MIN_DURATION)
}

// What the blind actually looks like over its life: full white for the first
// stretch, then clearing. Returned as 0..1 opacity so the client has nothing
// to decide.
FLASH_HOLD_FRACTION :: f32(0.35)

flash_opacity :: proc(remaining, total: f32) -> f32 {
	if remaining <= 0 || total <= 0 do return 0
	elapsed := total - remaining
	hold := total * FLASH_HOLD_FRACTION
	if elapsed <= hold do return 1

	t := (elapsed - hold) / max(total - hold, 0.001)
	// Squared: vision comes back slowly at first and then all at once, which
	// is both what eyes do and what makes the tail of a flash playable.
	return clamp((1 - t) * (1 - t), 0, 1)
}

// ------------------------------------------------------------------ molotov

// The bottle breaks into a patch of fire; the burning itself is a zone
// (game/zone.odin) rather than an instant effect.
MOLOTOV_ZONE :: Zone_Kind.Fire

// ------------------------------------------------------------------ shared

// What a detonation turns into. Damage comes back as a list rather than being
// applied, for the same reason the detonation itself did: only the caller
// knows about clients, scores and kill feeds.
Blast_Hit :: struct {
	pawn:     int,
	amount:   int,
	armor_pen: f32,
}

Blast :: struct {
	count: int,
	items: [MAX_PAWNS]Blast_Hit,
}

// Everyone an HE reached. Walls shield: the same sight test fog of war uses,
// so a wall that hides you also protects you.
he_blast :: proc(gs: ^Game_State, centre: [3]f32) -> (blast: Blast) {
	for &p, i in gs.pawns {
		if !p.active || !p.alive do continue

		// Measured to the chest rather than the feet, so a blast at the top of
		// a staircase does not treat someone below it as standing in it.
		target := p.body.position + {0, 0, p.body.height * 0.5}
		distance := linalg.length(target - centre)
		amount := he_damage_at(distance)
		if amount <= 0 do continue
		if !explosion_reaches(gs, centre, target) do continue

		if blast.count >= len(blast.items) do break
		blast.items[blast.count] = {
			pawn      = i,
			amount    = amount,
			armor_pen = HE_ARMOR_PEN,
		}
		blast.count += 1
	}
	return
}

// Everyone a flash caught, with how long each of them is out for.
Flash_Hit :: struct {
	pawn:     int,
	duration: f32,
}

Flash_Result :: struct {
	count: int,
	items: [MAX_PAWNS]Flash_Hit,
}

flash_blast :: proc(gs: ^Game_State, centre: [3]f32) -> (result: Flash_Result) {
	for &p, i in gs.pawns {
		if !p.active || !p.alive do continue

		eye := eye_position(p)
		blocked := sight_blocked(gs, eye, centre)
		duration := flash_duration(eye, view_forward(p.yaw, p.pitch), centre, blocked)
		if duration <= 0 do continue

		if result.count >= len(result.items) do break
		result.items[result.count] = {
			pawn     = i,
			duration = duration,
		}
		result.count += 1
	}
	return
}
