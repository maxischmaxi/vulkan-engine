package game

import "../physics"
import "core:math/rand"

// The entity both binaries simulate: the human and every bot are the same
// struct, which is what lets the server run one loop over all of them and the
// client predict itself with the very code the server verifies against.
// Purely client-side feelings -- damage flash, view smoothing -- live with the
// client, keyed off events and health changes rather than stored here.

// Roughly the counter-strike player: 32x32x72 units at 0.0254 m per unit.
PLAYER_RADIUS :: 0.3
PLAYER_HEIGHT :: 1.8
EYE_HEIGHT :: 1.65

// The ducked player: half the standing hull, eyes just under its top. Both
// numbers are the counter-strike ratios (36 and 28 of 72 units) applied to the
// height above.
CROUCH_HEIGHT :: 0.9
CROUCH_EYE_HEIGHT :: 0.75

// Half the hull is lost on ducking, and in mid-air half of that comes off the
// feet -- see physics.duck_hull. Quoted here because it is a number the map is
// laid out against, not an implementation detail.
AIR_DUCK_LIFT :: (PLAYER_HEIGHT - CROUCH_HEIGHT) * 0.5

// Source calls this sv_stepsize (18 units). Anything shorter than this gets
// walked over without a jump, which is what makes the stairs feel like ramps.
// It also bounds the mid-air duck's lift, since the camera unwinds both through
// the same smoothing.
STEP_HEIGHT :: 0.45
#assert(AIR_DUCK_LIFT <= STEP_HEIGHT)

PAWN_MAX_HEALTH :: 100
PAWN_MAX_ARMOR :: 100

// Counter-strike's kevlar: half of what gets through goes into the vest instead
// of the player, and the vest wears down by the amount it absorbed.
ARMOR_ABSORB :: 0.5

// One human plus five bots today; the array is sized for the humans a later
// server will hold.
MAX_PAWNS :: 16

// Humans one side holds. The server balances joins against it; the team
// select shows N OF TEAM_SIZE.
TEAM_SIZE :: 5

Team :: enum u8 {
	T, // attackers
	CT, // defenders
}

Pawn :: struct {
	active:        bool,
	is_bot:        bool,
	team:          Team,
	body:          physics.Body,
	prev_position: [3]f32, // start of the current tick, for render interpolation
	// Authoritative orientation. The client's camera writes these through its
	// input; bots steer them directly.
	yaw, pitch:    f32, // degrees
	crouching:     bool,
	noclip:        bool,
	// Debug affordances. Online they only exist if the server granted them --
	// a hardened server simply refuses the message that sets them.
	god:           bool,
	infinite_ammo: bool,
	health:        int,
	armor:         int,
	alive:         bool,
	respawn_in:    f32,
	// Sim state rather than input state: a jump pressed just before landing
	// must fire on the landing tick on both ends of a connection, so the
	// credit has to live where both ends simulate it.
	jump_buffer:   f32,
	// What this pawn carries. The buy menu writes it (via the server), spawn
	// applies it; init_pawn leaves it alone the way it leaves team alone.
	loadout:       Loadout,
	// The server's fire control state. The client keeps its own cosmetic copy
	// and never reads this locally.
	weapon:        Pawn_Weapon,
	// The grenade in hand, -1 for none. Deliberately NOT a weapon index: the
	// fire path carries the spray, the lag compensation and the anti-cheat
	// telemetry, and a throw has no business passing through any of it. The
	// trigger is taken off the command before the weapon sees it, exactly the
	// way the bomb does it.
	held_grenade:  i8,
	// The bomb in hand, which is what plants it. Same deal as the grenade: it
	// is not a weapon, it takes the trigger away, and at most one of the two is
	// ever set (hand.odin owns that invariant).
	holding_bomb:  bool,
	// Counts left this life, seeded from the loadout at spawn.
	grenades:      [Grenade_Kind]u8,
	// Seconds until another wind-up may start, so one click is one grenade.
	throw_cooldown: f32,
	// The arm drawing back before a throw. Counted in ticks rather than
	// seconds, because the client runs this very struct over the commands it
	// sends to draw its trajectory preview -- two integer counters over the
	// same commands agree exactly, two float accumulators would drift.
	wind_up:        Wind_Up,
	// Seconds of white left from a flash, and what it started at -- the client
	// needs both to draw the fade. Server-owned; it travels in the private
	// block, because being blind is nobody else's business.
	flash_left:    f32,
	flash_total:   f32,
	kills:         int,
	deaths:        int,
}

// Everything the simulation owns, as one value rather than a bag of globals:
// the server holds the authoritative one, the client holds the one it predicts
// into. The collision world lives here so the two binaries cannot bake it
// differently.
Game_State :: struct {
	tick:        u64,
	pawns:       [MAX_PAWNS]Pawn,
	// Grenades in the air. Server-authoritative and never predicted: nobody
	// steers one after it leaves the hand, so the client interpolates them the
	// way it interpolates other players.
	projectiles: [MAX_PROJECTILES]Projectile,
	// What grenades left behind: smoke that blocks sight, fire that burns.
	zones:       [MAX_ZONES]Effect_Zone,
	collision:   []physics.Aabb,
	grid:        physics.Grid,
	// Server-authoritative randomness only (bot AI, spawn picks, shot
	// inaccuracy). Prediction must never draw from this.
	rng:         rand.Generator,
}

// A fresh life at a spot. The hull is the player's; bots override theirs after
// the call, which beats a parameter nobody else passes.
init_pawn :: proc(p: ^Pawn, position: [3]f32, yaw: f32) {
	p.active = true
	p.body = physics.Body {
		position = position,
		radius   = PLAYER_RADIUS,
		height   = PLAYER_HEIGHT,
		step     = STEP_HEIGHT,
	}
	p.prev_position = position
	p.yaw = yaw
	p.pitch = 0
	p.crouching = false
	p.health = PAWN_MAX_HEALTH
	p.armor = PAWN_MAX_ARMOR
	p.alive = true
	p.respawn_in = 0
	p.jump_buffer = 0
	// Empty-handed until apply_loadout says otherwise, like the weapon slots.
	p.held_grenade = -1
	p.holding_bomb = false
	p.grenades = {}
	p.throw_cooldown = 0
	p.wind_up = {}
}

// Armour eats half of what is left, up to what the vest has, scaled down by
// how well the round penetrates (armor_pen 1 = the vest sees nothing, the
// default 0 = the vest's full absorb -- every pre-penetration call site keeps
// its behavior). Returns whether this was the killing blow; scorekeeping is
// the caller's business, because only the caller knows who fired.
damage_pawn :: proc(p: ^Pawn, amount: int, armor_pen: f32 = 0) -> (killed: bool) {
	if !p.alive || amount <= 0 do return false
	if p.god do return false

	taken := amount
	if p.armor > 0 {
		absorbed := min(p.armor, int(f32(taken) * ARMOR_ABSORB * (1 - armor_pen)))
		p.armor -= absorbed
		taken -= absorbed
	}

	p.health -= taken
	if p.health <= 0 {
		kill_pawn(p)
		return true
	}
	return false
}

kill_pawn :: proc(p: ^Pawn) {
	if !p.alive do return

	p.health = 0
	p.alive = false
	p.deaths += 1
	p.body.velocity = {}
}

eye_height_target :: proc(p: Pawn) -> f32 {
	return p.crouching ? CROUCH_EYE_HEIGHT : EYE_HEIGHT
}

// The eye in the simulation's own frame -- where shots and sight lines start.
// The client's rendered eye adds smoothing on top; that is cosmetic and never
// reaches the sim.
eye_position :: proc(p: Pawn) -> [3]f32 {
	return p.body.position + {0, 0, eye_height_target(p)}
}

// The box a shot has to intersect, at the pawn's simulation position.
pawn_hit_box :: proc(p: Pawn) -> physics.Aabb {
	return physics.body_aabb(p.body)
}
