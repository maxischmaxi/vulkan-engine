package game

import "../physics"

// Thrown grenades: what they are, how they fly, and when they go off. The
// flight itself is physics/bounce.odin; this file holds the numbers that make
// one grenade different from another, and the rule that turns a flying
// projectile into a detonation the caller has to act on.
//
// Deliberately free of any effect: what a detonation *does* lives with the
// server, because damage and blinding need the pawn list. Keeping the split
// here is what lets the whole flight path be tested without a wire.
//
// Nothing in here draws from gs.rng. A grenade's landing spot is the one thing
// a player practises for months, so it has to be a pure function of the throw.

Grenade_Kind :: enum u8 {
	He,
	Flash,
	Smoke,
	Molotov,
}

Grenade_Spec :: struct {
	name:        string,
	price:       int,
	teams:       bit_set[Team],
	// How many of this kind one player may carry. The total across all kinds
	// is capped separately by GRENADE_CARRY_TOTAL.
	max_carried: int,
	// Seconds from the throw to going off. Ignored when detonate_on_rest is
	// set, where landing is the trigger instead.
	fuse:        f32,
	// Smoke and fire start where they land rather than after a countdown, so a
	// smoke thrown into a corner blooms in that corner.
	on_rest:     bool,
	// How the thing behaves off a wall: how much speed survives along the
	// normal, and how much along the surface.
	restitution: f32,
	friction:    f32,
	radius:      f32,
}

@(rodata)
GRENADES := [Grenade_Kind]Grenade_Spec {
	.He = {
		name = "he",
		price = 300,
		teams = {.T, .CT},
		max_carried = 1,
		fuse = 1.6,
		restitution = 0.45,
		friction = 0.8,
		radius = 0.09,
	},
	.Flash = {
		name = "flash",
		price = 200,
		teams = {.T, .CT},
		// The one grenade worth carrying two of: one to pop for yourself, one
		// to throw for a teammate.
		max_carried = 2,
		fuse = 1.6,
		restitution = 0.45,
		friction = 0.8,
		radius = 0.09,
	},
	.Smoke = {
		name = "smoke",
		price = 300,
		teams = {.T, .CT},
		max_carried = 1,
		// Never counts down: it blooms where it stops.
		on_rest = true,
		// Deader than the others, so it settles roughly where it is aimed
		// instead of rolling out of the choke it was meant to block.
		restitution = 0.25,
		friction = 0.55,
		radius = 0.1,
	},
	.Molotov = {
		name = "molotov",
		price = 400,
		// The one asymmetric buy, as in counter-strike. Same behaviour on both
		// sides; only the name and the side differ.
		teams = {.T},
		max_carried = 1,
		on_rest = true,
		// A bottle does not bounce, it breaks.
		restitution = 0.05,
		friction = 0.4,
		radius = 0.1,
	},
}

GRENADE_COUNT :: len(Grenade_Kind)

// Total grenades one player may carry across all kinds.
GRENADE_CARRY_TOTAL :: 4

// How hard it was thrown. Counter-strike's three, off the two mouse buttons:
// left alone throws long, right alone lobs it just ahead, both together splits
// the difference.
Throw_Mode :: enum u8 {
	Long,
	Medium,
	Short,
}

// Metres per second out of the hand. The long throw is counter-strike's 750
// units per second expressed in this project's units.
THROW_SPEED := [Throw_Mode]f32 {
	.Long   = 750 * UNIT,
	.Medium = 500 * UNIT,
	.Short  = 250 * UNIT,
}

// Grenades leave the hand a little above the aim line, which is what makes a
// flat-aimed long throw travel rather than hit the floor.
THROW_PITCH_LIFT :: f32(7)

// How much of the thrower's own motion carries into the throw. Running throws
// go further -- counter-strike does the same, and it is what makes a run-up
// smoke a thing worth practising.
THROW_INHERIT :: f32(0.6)

// Where the grenade appears: at eye level and far enough forward that it never
// starts inside the thrower's own hull.
THROW_FORWARD :: f32(0.45)

MAX_PROJECTILES :: 16

Projectile :: struct {
	active:    bool,
	kind:      Grenade_Kind,
	owner:     int, // pawn id, for kill credit
	team:      Team,
	position:  [3]f32,
	velocity:  [3]f32,
	fuse:      f32, // seconds left; only meaningful when the spec has one
	// Ticks spent stationary. A grenade that lands on a slope creeps for a
	// moment, so resting is confirmed over a few ticks rather than instantly.
	rest_time: f32,
	age:       f32, // seconds since the throw, for the backstop below
}

// Confirmed-at-rest threshold for the on_rest kinds.
PROJECTILE_REST_TIME :: f32(0.1)

// A projectile that has been in the world this long goes off wherever it is,
// even if it never settled -- one wedged where it can creep forever must not
// become a permanent entity.
PROJECTILE_MAX_LIFE :: f32(12)

// What came off a projectile this tick, for the caller to turn into damage,
// smoke or fire. Position rather than index: the projectile is gone by then.
Detonation :: struct {
	kind:     Grenade_Kind,
	owner:    int,
	team:     Team,
	position: [3]f32,
}

Detonation_Events :: struct {
	count: int,
	items: [MAX_PROJECTILES]Detonation,
}

grenade_allowed :: proc(kind: Grenade_Kind, team: Team) -> bool {
	return team in GRENADES[kind].teams
}

// The velocity a throw leaves the hand with. Pure, and quantized-angle safe:
// it reads the same yaw and pitch the wire carries, so both ends compute the
// same arc.
throw_velocity :: proc(yaw, pitch: f32, mode: Throw_Mode, thrower_velocity: [3]f32) -> [3]f32 {
	dir := view_forward(yaw, clamp(pitch + THROW_PITCH_LIFT, -89, 89))
	return dir * THROW_SPEED[mode] + thrower_velocity * THROW_INHERIT
}

throw_origin :: proc(p: Pawn) -> [3]f32 {
	return eye_position(p) + view_forward(p.yaw, p.pitch) * THROW_FORWARD
}

// Puts one in the air. Returns false when the world is already holding as many
// as it can, which the caller should treat as the throw not happening at all
// rather than as a grenade silently vanishing from the inventory.
spawn_projectile :: proc(
	gs: ^Game_State,
	kind: Grenade_Kind,
	owner: int,
	team: Team,
	position: [3]f32,
	velocity: [3]f32,
) -> bool {
	for &p in gs.projectiles {
		if p.active do continue
		p = Projectile {
			active   = true,
			kind     = kind,
			owner    = owner,
			team     = team,
			position = position,
			velocity = velocity,
			fuse     = GRENADES[kind].fuse,
		}
		return true
	}
	return false
}

// One tick of every projectile in the world. Detonations come back rather than
// being applied, because applying them needs the things this package has no
// business reaching into.
tick_projectiles :: proc(gs: ^Game_State, dt: f32) -> (events: Detonation_Events) {
	for &p in gs.projectiles {
		if !p.active do continue

		spec := GRENADES[p.kind]
		result := physics.bounce_move(
			&gs.grid,
			&p.position,
			&p.velocity,
			spec.radius,
			GRAVITY,
			spec.restitution,
			spec.friction,
			dt,
		)

		p.age += dt
		if result.resting {
			p.rest_time += dt
		} else {
			p.rest_time = 0
		}

		// Fell out of the world: gone without going off, so nothing downstream
		// has to cope with a detonation under the map.
		if p.position.z < -50 {
			p.active = false
			continue
		}

		// A fuse burns whether the thing is flying or lying still; the on_rest
		// kinds have none and wait to settle instead.
		detonate := false
		if spec.on_rest {
			detonate = p.rest_time >= PROJECTILE_REST_TIME
		} else {
			p.fuse -= dt
			detonate = p.fuse <= 0
		}

		// The backstop, for the on_rest kinds above all: something wedged
		// where it can creep forever must still leave the world rather than
		// becoming a permanent entity.
		if p.age >= PROJECTILE_MAX_LIFE do detonate = true

		if !detonate do continue

		p.active = false
		if events.count < len(events.items) {
			events.items[events.count] = {
				kind     = p.kind,
				owner    = p.owner,
				team     = p.team,
				position = p.position,
			}
			events.count += 1
		}
	}
	return
}

// Distance falloff shared with the bomb: full damage at the centre, nothing at
// the edge, linear between. Written once so a change to how explosions feel
// cannot apply to only one of them.
explosion_damage :: proc(max_damage: int, distance, radius: f32) -> int {
	if distance >= radius do return 0
	return int(f32(max_damage) * (1 - distance / radius))
}

// How much of a blast a point actually receives, given the world between it
// and the centre. Explosions do not go through walls; they do go round
// corners badly, which the sight test approximates well enough.
explosion_reaches :: proc(gs: ^Game_State, from, to: [3]f32) -> bool {
	return !sight_blocked(gs, from, to)
}
