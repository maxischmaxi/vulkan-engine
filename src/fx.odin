package main

import "core:math"
import "core:math/linalg"
import "game"
import "physics"
import "protocol"

// What a detonation looks and sounds like. One entry point, one table of
// bursts, built the way audio_bank.odin is built and for the same reason: the
// place a new effect is added should be obvious and small.
//
// The split against game/grenade_effect.odin is the same split that runs
// through the whole project. That file decides what an explosion DOES -- how
// much damage, how long the blind, how wide the cloud -- on both ends of the
// wire. This one only decides what it looks like, on one end, and nothing here
// can change the outcome of anything.
//
// The server says a detonation happened by way of a world event
// (protocol.Event_Kind); the client never infers one from a projectile
// disappearing, because one dropped datagram imitates that perfectly.

// One puff of particles: a cone of them, with the shapes each end of their life
// takes. Everything an effect is made of is one of these plus a light.
Fx_Burst :: struct {
	count:      int,
	look:       Particle_Look,
	axis:       [3]f32, // the cone's direction; {0,0,1} is straight up
	spread:     f32, // half angle in degrees, 180 for a full sphere
	speed:      [2]f32, // min, max, metres a second
	drag:       f32,
	gravity:    f32, // a multiple of world gravity; negative rises
	size:       [2]f32, // diameter at birth and at death, metres
	color_from: [4]f32, // rgb plus opacity
	color_to:   [4]f32,
	life:       [2]f32, // min, max seconds
	spawn:      f32, // scattered this far around the centre
	rise:       f32, // and this far above it
}

// Fires one burst at a place.
fx_burst :: proc(b: Fx_Burst, centre: [3]f32) {
	for _ in 0 ..< b.count {
		direction := particle_cone(b.axis, b.spread)
		offset := b.spawn > 0 ? particle_cone({0, 0, 1}, 180) * particle_random(0, b.spawn) : {}

		spawn_particle(
			{
				position = centre + offset + {0, 0, b.rise},
				velocity = direction * particle_random(b.speed[0], b.speed[1]),
				drag = b.drag,
				gravity = b.gravity,
				size_from = b.size[0],
				size_to = b.size[1],
				color_from = b.color_from,
				color_to = b.color_to,
				life = particle_random(b.life[0], b.life[1]),
				look = b.look,
			},
		)
	}
}

// ------------------------------------------------------------------- the he

// The fireball: out fast, stopped almost at once by drag, white hot fading
// through orange. Short -- the light is what sells the moment, this is what
// gives it a shape.
HE_FIRE := Fx_Burst {
	count      = 16,
	look       = .Fire,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {5, 15},
	drag       = 7,
	gravity    = -0.05,
	// Small at birth and not enormous at death: a fireball is read from the
	// shape of the pile, and quads wide enough to each cover it individually
	// turn the pile into one disc.
	size       = {0.3, 1.5},
	// Far redder than a flame looks on its own, and on purpose. Additive
	// blending SUMS these and the framebuffer clips each channel at one: at a
	// balanced yellow, three overlapping quads clip all three channels together
	// and the pile comes out white. Starting with the green and blue well down
	// means the red clips first and the stack stays orange, with white only
	// where it is genuinely dense. An HDR target with a bloom pass would not
	// need the trick -- this one has neither.
	color_from = {1.0, 0.40, 0.10, 1},
	color_to   = {0.55, 0.08, 0.02, 0},
	life       = {0.26, 0.45},
	spawn      = 0.25,
	rise       = 0.15,
}

// The middle of the fireball. The shell above spreads out and leaves a ring of
// separate blobs with a hole in it; this fills the hole. Two layers rather than
// one denser burst, because what a fireball looks like is a bright centre with
// a broken edge, and a single speed range gives an even one.
HE_CORE := Fx_Burst {
	count      = 8,
	look       = .Fire,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {0.5, 4},
	drag       = 9,
	gravity    = -0.08,
	size       = {0.7, 2.0},
	color_from = {1.0, 0.55, 0.18, 1},
	color_to   = {0.5, 0.07, 0.02, 0},
	life       = {0.2, 0.34},
	spawn      = 0.15,
	rise       = 0.2,
}

// The smoke that outlives it, rising and spreading. This is what is still there
// a second later and what makes the blast read as having happened.
HE_SMOKE := Fx_Burst {
	count      = 16,
	look       = .Soft,
	axis       = {0, 0, 1},
	spread     = 105,
	speed      = {1.4, 4.5},
	drag       = 2.2,
	gravity    = -0.10, // hot air rises
	size       = {0.7, 3.4},
	color_from = {0.30, 0.28, 0.26, 0.75},
	color_to   = {0.46, 0.45, 0.44, 0},
	life       = {1.1, 1.9},
	spawn      = 0.3,
	rise       = 0.2,
}

// Fragments, thrown hard and pulled straight back down.
HE_SPARKS := Fx_Burst {
	count      = 26,
	look       = .Spark,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {8, 22},
	drag       = 1.2,
	gravity    = 1,
	size       = {0.035, 0.012},
	color_from = {1.0, 0.52, 0.16, 1},
	color_to   = {0.9, 0.18, 0.03, 0},
	life       = {0.3, 0.65},
	spawn      = 0.1,
	rise       = 0.15,
}

// The ring of dust thrown outward along the ground. Without it the whole thing
// hangs in the air with nothing under it; this is what plants it on the floor.
HE_DUST := Fx_Burst {
	count      = 12,
	look       = .Soft,
	axis       = {0, 0, 1},
	spread     = 180, // flattened by the near-zero vertical speed below
	speed      = {5, 9},
	drag       = 4.5,
	gravity    = 0.02,
	size       = {0.5, 2.8},
	color_from = {0.52, 0.47, 0.40, 0.5},
	color_to   = {0.58, 0.55, 0.50, 0},
	life       = {0.6, 1.0},
	spawn      = 0.15,
	rise       = 0.1,
}

// ---------------------------------------------------------------- the flash

// Barely anything to look at, and deliberately: what a flashbang IS is the
// light, which is why the spec below drives it to an intensity nothing else in
// the game comes near. These few are the shape the light comes out of.
FLASH_BURST := Fx_Burst {
	count      = 7,
	look       = .Fire,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {6, 14},
	drag       = 9,
	gravity    = 0,
	size       = {0.6, 2.6},
	color_from = {1.0, 0.99, 0.95, 1},
	color_to   = {0.85, 0.90, 1.0, 0},
	life       = {0.10, 0.18},
	spawn      = 0.1,
	rise       = 0.1,
}

// ---------------------------------------------------------------- the smoke

// The canister letting go. Fast and low, before the cloud itself takes over.
SMOKE_POP := Fx_Burst {
	count      = 22,
	look       = .Soft,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {3, 7},
	drag       = 3.5,
	gravity    = -0.05,
	size       = {0.6, 2.6},
	color_from = {0.70, 0.71, 0.72, 0.7},
	color_to   = {0.62, 0.64, 0.66, 0},
	life       = {0.7, 1.3},
	spawn      = 0.2,
	rise       = 0.15,
}

// Emitted every frame while a cloud is alive, at its rim. The volumetric shader
// draws a sphere, and a sphere always looks like a sphere; these are what break
// that silhouette up into something that reads as smoke.
SMOKE_CURL := Fx_Burst {
	count      = 1,
	look       = .Soft,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {0.15, 0.7},
	drag       = 1.2,
	gravity    = -0.02,
	size       = {1.0, 2.2},
	color_from = {0.66, 0.67, 0.69, 0.30},
	color_to   = {0.60, 0.62, 0.65, 0},
	life       = {1.2, 2.2},
}

// Puffs a second at the rim of a full-sized cloud, scaled by how grown it is.
SMOKE_CURL_RATE :: f32(14)

// ----------------------------------------------------------------- the fire

// Glass going, then the pool catching.
FIRE_POP := Fx_Burst {
	count      = 14,
	look       = .Spark,
	axis       = {0, 0, 1},
	spread     = 180,
	speed      = {3, 9},
	drag       = 2,
	gravity    = 1,
	size       = {0.04, 0.015},
	color_from = {1.0, 0.48, 0.14, 1},
	color_to   = {0.85, 0.16, 0.03, 0},
	life       = {0.3, 0.7},
	spawn      = 0.15,
	rise       = 0.1,
}

// Flames licking up off the burning ground, emitted for the zone's whole life.
FIRE_FLAME := Fx_Burst {
	count      = 1,
	look       = .Fire,
	axis       = {0, 0, 1},
	spread     = 22,
	speed      = {1.2, 2.6},
	drag       = 1.4,
	gravity    = -0.16,
	size       = {0.55, 0.15},
	color_from = {1.0, 0.34, 0.07, 1},
	color_to   = {0.6, 0.09, 0.02, 0},
	life       = {0.45, 0.8},
	rise       = 0.05,
}

// And the embers going up with them, which is what makes a fire read from far
// enough away that the flames themselves are a few pixels.
FIRE_EMBER := Fx_Burst {
	count      = 1,
	look       = .Spark,
	axis       = {0, 0, 1},
	spread     = 30,
	speed      = {1.5, 3.5},
	drag       = 0.8,
	gravity    = -0.25,
	size       = {0.035, 0.01},
	color_from = {1.0, 0.45, 0.12, 1},
	color_to   = {0.85, 0.14, 0.02, 0},
	life       = {0.7, 1.4},
	rise       = 0.1,
}

FIRE_FLAME_RATE :: f32(30)
FIRE_EMBER_RATE :: f32(9)

// --------------------------------------------------------------- the lights

// A detonation's light, and how long it lasts. The flash's numbers are absurd
// next to the others on purpose: nothing else in this game is supposed to burn
// out a wall, and a flashbang that merely glowed would be a firework.
FX_LIGHTS := [protocol.Event_Kind]struct {
	color:     [3]f32,
	intensity: f32,
	radius:    f32,
	time:      f32,
} {
	.Footstep  = {},
	.Gunshot   = {},
	.He_Blast  = {{1.0, 0.62, 0.28}, 55, 13, 0.26},
	.Flash_Pop = {{1.0, 0.98, 0.94}, 260, 20, 0.14},
	.Smoke_Pop = {},
	.Fire_Pop  = {{1.0, 0.55, 0.18}, 30, 8, 0.5},
}

// ------------------------------------------------------------------ the door

// Something went off at a place. Everything a detonation is made of happens
// here: particles, light, a mark on the ground, the shove to the view, the
// noise.
fx_emit :: proc(kind: protocol.Event_Kind, position: [3]f32) {
	light := FX_LIGHTS[kind]
	if light.intensity > 0 {
		// Lifted off the floor, or half the light is spent on the metre of
		// ground directly under the blast.
		add_transient_light(
			position + {0, 0, 0.5},
			light.color,
			light.intensity,
			light.radius,
			light.time,
		)
	}

	switch kind {
	case .Footstep, .Gunshot:
	// not detonations; remote.odin never routes them here

	case .He_Blast:
		fx_burst(HE_CORE, position)
		fx_burst(HE_FIRE, position)
		fx_burst(HE_SPARKS, position)
		fx_burst(HE_SMOKE, position)
		fx_flat_burst(HE_DUST, position)
		fx_scorch(position, 2.6)
		viewpunch_note_blast(position, 1)
		audio_emit({kind = .Explosion, pos = position})

	case .Flash_Pop:
		fx_burst(FLASH_BURST, position)
		viewpunch_note_blast(position, 0.45)
		audio_emit({kind = .Flash_Pop, pos = position})

	case .Smoke_Pop:
		fx_burst(SMOKE_POP, position)
		audio_emit({kind = .Smoke_Hiss, pos = position})

	case .Fire_Pop:
		fx_burst(FIRE_POP, position)
		fx_scorch(position, 1.8)
		audio_emit({kind = .Fire_Start, pos = position})
	}
}

// --fx=KIND: set the effect off on a slow cycle a few metres in front of the
// camera. A detonation is a server event, so without this there is no way to
// photograph one at all -- no match, no throw, no keyboard. The effect bank's
// equivalent of --hudpreview, and the same reasoning behind it.
FX_PROBE_PERIOD :: f32(2.5)
FX_PROBE_DISTANCE :: f32(7)

@(private = "file")
fx_probe_kind :: proc() -> (kind: protocol.Event_Kind, ok: bool) {
	switch cli.fx {
	case "he":
		return .He_Blast, true
	case "flash":
		return .Flash_Pop, true
	case "smoke":
		return .Smoke_Pop, true
	case "fire":
		return .Fire_Pop, true
	}
	return {}, false
}

fx_probe_tick :: proc() {
	if cli.fx == "" do return
	kind, ok := fx_probe_kind()
	if !ok do return

	// On the wall clock, not on a frame counter: the point is a fixed cadence a
	// screenshot script can time against.
	@(static) elapsed: f32
	@(static) seeded: bool
	elapsed += game.clock.frame_dt
	if seeded && elapsed < FX_PROBE_PERIOD do return
	elapsed = 0
	seeded = true

	// Ahead of the eye at eye height, then dropped onto whatever is under it --
	// an explosion hanging in mid air says nothing about how it sits on ground.
	forward := game.yaw_forward_flat(camera.yaw)
	at := camera.position + forward * FX_PROBE_DISTANCE
	if z, found := physics.grid_ground_below(&gs.grid, at, 6); found {
		at.z = z + 0.2
	}
	fx_emit(kind, at)
}

// A burst pushed flat: the same cone, with the vertical thrown away. What makes
// the dust ring a ring rather than another ball.
@(private = "file")
fx_flat_burst :: proc(b: Fx_Burst, centre: [3]f32) {
	for _ in 0 ..< b.count {
		direction := particle_cone(b.axis, b.spread)
		direction.z *= 0.08
		direction = linalg.normalize0(direction)
		if direction == {} do continue

		spawn_particle(
			{
				position = centre + {0, 0, b.rise},
				velocity = direction * particle_random(b.speed[0], b.speed[1]),
				drag = b.drag,
				gravity = b.gravity,
				size_from = b.size[0],
				size_to = b.size[1],
				color_from = b.color_from,
				color_to = b.color_to,
				life = particle_random(b.life[0], b.life[1]),
				look = b.look,
			},
		)
	}
}

// The mark a blast leaves, on whatever is under it. Traced downward rather than
// assumed: a grenade going off on a catwalk must scorch the catwalk, not the
// floor of the room below.
@(private = "file")
fx_scorch :: proc(position: [3]f32, size: f32) {
	// The client's own collision copy, baked from the same brushes as the
	// server's -- the grid the shot trace already runs against.
	z, found := physics.grid_ground_below(&gs.grid, position + {0, 0, 0.4}, 2.5)
	if !found do return
	add_decal({position.x, position.y, z}, {0, 0, 1}, particle_random(0, 1), size, .Scorch)
}

// ------------------------------------------------------------- zone emitters

// Smoke clouds and fires are not one-off bursts: they are alive for seconds and
// have to keep producing. Called every frame from submit_zones with the zone's
// own id, so each cloud carries its own fractional remainder -- without one, a
// rate below one particle a frame rounds to nothing at every frame rate this
// runs at.
//
// One remainder per emitter as well as per zone. Sharing a fire's flames and
// its embers on a single accumulator was tried and is quietly wrong: the two
// rates add into the same number and then split between them by whichever ran
// first, so neither comes out at the rate it asked for.
Fx_Emitter :: enum u8 {
	Smoke_Curl,
	Fire_Flame,
	Fire_Ember,
}

fx_zone_carry: [protocol.MAX_SNAPSHOT_ZONES][Fx_Emitter]f32

fx_reset_zones :: proc() {
	fx_zone_carry = {}
}

// Returns how many whole particles this zone owes this frame.
@(private = "file")
fx_zone_due :: proc(id: u8, emitter: Fx_Emitter, rate, dt: f32) -> int {
	carry := &fx_zone_carry[int(id) % len(fx_zone_carry)][emitter]
	carry^ += rate * dt
	whole := int(carry^)
	carry^ -= f32(whole)
	return whole
}

// The rim of a growing or standing cloud.
fx_smoke_cloud :: proc(id: u8, centre: [3]f32, radius, full_radius, dt: f32) {
	if radius <= 0.1 do return
	// Scaled by how grown the cloud is, so a blooming smoke churns hardest
	// while it is spreading and settles once it has.
	rate := SMOKE_CURL_RATE * clamp(radius / max(full_radius, 0.001), 0, 1)
	for _ in 0 ..< fx_zone_due(id, .Smoke_Curl, rate, dt) {
		// On the surface of the sphere, not inside it: the inside is the
		// volumetric shader's job and a particle there is invisible anyway.
		direction := particle_cone({0, 0, 1}, 180)
		fx_burst_at(SMOKE_CURL, centre + direction * (radius * particle_random(0.75, 1.0)))
	}
}

// Flames and embers off a patch of burning ground.
fx_fire_zone :: proc(id: u8, centre: [3]f32, radius, dt: f32) {
	if radius <= 0.05 do return

	scatter :: proc(centre: [3]f32, radius: f32) -> [3]f32 {
		// Uniform over the disc: a linear radius crowds everything into the
		// middle and leaves the rim of the fire bare.
		angle := particle_random(0, math.TAU)
		r := radius * math.sqrt(particle_random(0, 1))
		return centre + {math.cos(angle) * r, math.sin(angle) * r, 0}
	}

	for _ in 0 ..< fx_zone_due(id, .Fire_Flame, FIRE_FLAME_RATE * radius, dt) {
		fx_burst_at(FIRE_FLAME, scatter(centre, radius))
	}
	for _ in 0 ..< fx_zone_due(id, .Fire_Ember, FIRE_EMBER_RATE * radius, dt) {
		fx_burst_at(FIRE_EMBER, scatter(centre, radius))
	}
}

// One particle from a burst spec, at an exact place. The continuous emitters
// place each particle themselves, so they cannot go through fx_burst's own
// scatter.
fx_burst_at :: proc(b: Fx_Burst, at: [3]f32) {
	direction := particle_cone(b.axis, b.spread)
	spawn_particle(
		{
			position = at + {0, 0, b.rise},
			velocity = direction * particle_random(b.speed[0], b.speed[1]),
			drag = b.drag,
			gravity = b.gravity,
			size_from = b.size[0],
			size_to = b.size[1],
			color_from = b.color_from,
			color_to = b.color_to,
			life = particle_random(b.life[0], b.life[1]),
			look = b.look,
		},
	)
}
