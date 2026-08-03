package game

import "core:math"

// What a grenade leaves behind: a smoke cloud, or a patch of burning ground.
// Both are volumes that exist for a while, grow when they land and shrink when
// they die, so they share a struct rather than each inventing one.
//
// Smoke blocks sight (see sight_blocked in visibility.odin), fire does damage.
// Neither blocks bullets -- counter-strike's rule, and it keeps the whole of
// this out of the lag compensation.

Zone_Kind :: enum u8 {
	Smoke,
	Fire,
}

Zone_Spec :: struct {
	// Total life, including bloom and fade.
	duration:   f32,
	// The radius it reaches once fully grown.
	radius:     f32,
	// Seconds spent growing to that radius, and shrinking away at the end. A
	// smoke that blocked instantly would make the throw unreadable; one that
	// vanished instantly would end a fight on a frame.
	bloom:      f32,
	fade:       f32,
	// Health per second to anything standing in it. Smoke does none.
	damage_dps: f32,
}

@(rodata)
ZONE_SPECS := [Zone_Kind]Zone_Spec {
	.Smoke = {duration = 17, radius = 3.4, bloom = 1.0, fade = 1.5, damage_dps = 0},
	.Fire = {duration = 7, radius = 1.9, bloom = 0.4, fade = 0.6, damage_dps = 38},
}

MAX_ZONES :: 8

Effect_Zone :: struct {
	active:   bool,
	kind:     Zone_Kind,
	position: [3]f32,
	owner:    int, // pawn id, for kill credit
	team:     Team,
	age:      f32,
	// Damage is dealt in whole points on a fixed cadence rather than fractions
	// every tick: health is an integer, and 38 dps at 64 Hz would round to
	// nothing every single tick.
	burn:     f32,
}

// Fire ticks its damage this often. Slow enough that each tick is a readable
// chunk of health, fast enough that walking through a corner of it still costs
// something.
FIRE_TICK :: f32(0.25)

// How wide a zone is right now: growing, full, or shrinking. A zone past its
// duration has no radius at all, which is what makes expiry a pure function of
// age rather than a flag someone has to remember to clear.
zone_radius :: proc(kind: Zone_Kind, age: f32) -> f32 {
	spec := ZONE_SPECS[kind]
	if age < 0 || age >= spec.duration do return 0

	if age < spec.bloom {
		// Eased rather than linear: a cloud billows out fast and settles.
		t := age / spec.bloom
		return spec.radius * math.sqrt(t)
	}

	fade_start := spec.duration - spec.fade
	if age > fade_start && spec.fade > 0 {
		t := (age - fade_start) / spec.fade
		return spec.radius * (1 - t)
	}
	return spec.radius
}

zone_expired :: proc(z: Effect_Zone) -> bool {
	return z.age >= ZONE_SPECS[z.kind].duration
}

// Whether a point is inside the zone as it stands this instant. Height counts:
// a smoke on the floor below does not blind the walkway above it.
zone_contains :: proc(z: Effect_Zone, point: [3]f32) -> bool {
	r := zone_radius(z.kind, z.age)
	if r <= 0 do return false
	delta := point - z.position
	return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z <= r * r
}

// Puts one in the world. Returns false when they are all taken, which the
// caller should log rather than swallow -- a smoke that never appears is a
// round decided by a missing entity.
spawn_zone :: proc(gs: ^Game_State, kind: Zone_Kind, owner: int, team: Team, position: [3]f32) -> bool {
	for &z in gs.zones {
		if z.active do continue
		z = Effect_Zone {
			active   = true,
			kind     = kind,
			position = position,
			owner    = owner,
			team     = team,
		}
		return true
	}
	return false
}

// One pawn caught in a burning zone this tick.
Burn_Hit :: struct {
	pawn:   int,
	owner:  int,
	amount: int,
}

Burn_Events :: struct {
	count: int,
	items: [MAX_PAWNS]Burn_Hit,
}

// Ages every zone and reports the burns. Damage is returned rather than
// applied for the same reason detonations are: scorekeeping needs the caller.
tick_zones :: proc(gs: ^Game_State, dt: f32) -> (events: Burn_Events) {
	for &z in gs.zones {
		if !z.active do continue

		z.age += dt
		if zone_expired(z) {
			z.active = false
			continue
		}

		spec := ZONE_SPECS[z.kind]
		if spec.damage_dps <= 0 do continue

		z.burn += dt
		if z.burn < FIRE_TICK do continue
		z.burn -= FIRE_TICK

		amount := int(spec.damage_dps * FIRE_TICK)
		if amount <= 0 do continue

		for &p, i in gs.pawns {
			if !p.active || !p.alive do continue
			// The feet, not the eyes: standing in fire is what burns, and a
			// tall pawn's head can be clear of a low flame.
			if !zone_contains(z, p.body.position) do continue
			if events.count >= len(events.items) do break

			events.items[events.count] = {
				pawn   = i,
				owner  = z.owner,
				amount = amount,
			}
			events.count += 1
		}
	}
	return
}

// Whether a sight line crosses enough smoke to be blocked. Used by
// sight_blocked, so the server's fog of war and the client's own reasoning read
// the same clouds.
//
// A chord through the sphere rather than a plain hit test: clipping the very
// edge of a cloud should not hide anything, and this is the number that says
// how much smoke the line actually went through.
SMOKE_BLOCK_CHORD :: f32(1.2)

zone_blocks_sight :: proc(z: Effect_Zone, from, to: [3]f32) -> bool {
	if !z.active || z.kind != .Smoke do return false
	r := zone_radius(z.kind, z.age)
	if r <= 0 do return false
	return sphere_chord(from, to, z.position, r) >= min(SMOKE_BLOCK_CHORD, r * 1.6)
}

// Length of the segment from->to that lies inside the sphere. Zero when it
// misses, or when the sphere is entirely behind or beyond the segment.
@(private = "file")
sphere_chord :: proc(from, to, centre: [3]f32, radius: f32) -> f32 {
	d := to - from
	length_sq := d.x * d.x + d.y * d.y + d.z * d.z
	if length_sq < 1e-9 do return 0
	length := math.sqrt(length_sq)
	dir := d / length

	m := from - centre
	b := m.x * dir.x + m.y * dir.y + m.z * dir.z
	c := m.x * m.x + m.y * m.y + m.z * m.z - radius * radius

	discriminant := b * b - c
	if discriminant <= 0 do return 0

	root := math.sqrt(discriminant)
	t0 := clamp(-b - root, 0, length)
	t1 := clamp(-b + root, 0, length)
	return max(t1 - t0, 0)
}
