package protocol

import "../game"

// The server's world, once per tick, delta-encoded against the newest
// snapshot the client has acknowledged. baseline_tick names that snapshot;
// 0 means the baseline is an empty world, which makes a full snapshot just a
// delta against nothing -- one code path serves both.
//
// Field comparisons happen on the WIRE representation (quantized yaw, coarse
// pitch, f32 bits), never on raw floats: the receiver's baseline holds the
// dequantized wire values, and only wire-space equality keeps both ends
// agreeing bit for bit about what "unchanged" means.

Entity_Flag :: enum u8 {
	Alive,
	Crouching,
	On_Ground,
	Is_Bot,
	Team_CT, // set = CT, clear = T
	Fired, // fired this tick: the client's cue for a remote muzzle flash
}

Entity_Flags :: bit_set[Entity_Flag;u8]

// Which pawn ids exist in a snapshot. The entity array is indexed by pawn id,
// so a cleared bit both removes the pawn and skips its bytes.
Present_Mask :: bit_set[0 ..< game.MAX_PAWNS;u16]

// Which fields of one entity differ from the baseline and follow on the wire.
Entity_Field :: enum u8 {
	Flags,
	Pos_X,
	Pos_Y,
	Pos_Z,
	Yaw,
	Pitch,
	Health,
	Weapon,
}

Field_Mask :: bit_set[Entity_Field;u8]

FIELD_MASK_ALL :: Field_Mask{.Flags, .Pos_X, .Pos_Y, .Pos_Z, .Yaw, .Pitch, .Health, .Weapon}

Snapshot_Entity :: struct {
	flags:    Entity_Flags,
	position: [3]f32,
	yaw:      f32, // quantized on the wire
	pitch:    f32, // coarse (u8) -- display only
	health:   u8,
	weapon:   u8,
}

// What only the owning client may know about itself. Velocity is what
// reconciliation replays from; the ammo numbers drive the HUD. Always sent in
// full -- velocity churns every tick anyway.
// What the owning client is actually wearing this tick, as opposed to what its
// buy menu has pending. The HUD reads these; a mid-round buy that the server
// stored for the next spawn must not light them up early.
Private_Gear :: enum u8 {
	Helmet,
	Defuse_Kit,
}

Private_Gear_Flags :: bit_set[Private_Gear;u8]

Private_State :: struct {
	velocity:       [3]f32,
	armor:          u8,
	gear:           Private_Gear_Flags,
	ammo_mag:       u8,
	ammo_reserve:   u8,
	cooldown_ticks: u8,
	reload_ticks:   u8,
	kills:          u8,
	deaths:         u8,
	// The server's burst: depth in eighths of a shot, and the seed its pattern
	// was rolled from -- the client mirror rebuilds the points from the seed
	// and adopts the depth only when locally idle (predict.odin).
	spray_progress: u8,
	spray_seed:     u32,
	// Competitive money; TDM sends 0. u16 covers the $16000 cap comfortably.
	money:          u16,
	// Being blinded is nobody else's business, so it rides in the private
	// block: how much white is left, and what it started at. Sent as
	// centiseconds; a flash is seconds long and nothing is decided by the
	// hundredth.
	flash_left_cs:  u16,
	flash_total_cs: u16,
	// What is left on the belt, and what the server has in this pawn's hands
	// (a game.Hand as a select code). Both are the owner's business only, and
	// without them the client cannot draw a belt it has been throwing from --
	// the loadout it bought stops being the truth at the first throw.
	grenades:       [game.GRENADE_COUNT]u8,
	hand:           i8,
}

// Something that happened at a place this tick, for the client to hear and to
// show. Filtered by range rather than by sight -- that split is the whole
// reason this block exists. With fog of war a pawn nobody can see is absent
// from the entity array, and the client used to derive remote footsteps and
// gunfire from exactly that array, so an unseen enemy would also have been an
// inaudible one.
//
// Detonations ride here too, and not in a block of their own: they are the same
// shape of fact -- one tick, one position, no history worth repairing. Without
// them the client learns of an explosion only by a projectile going missing
// from the snapshot, which a single dropped datagram fakes perfectly.
//
// Transient by nature, so they are never delta-encoded: a lost datagram costs
// one footstep, and repairing it a tick later would only play it in the wrong
// place.
Event_Kind :: enum u8 {
	Footstep,
	Gunshot,
	He_Blast,
	Flash_Pop,
	Smoke_Pop,
	Fire_Pop,
}

World_Event :: struct {
	kind:     Event_Kind,
	weapon:   u8, // gunshot only -- the bank picks the sample from it
	position: [3]f32, // quantized on the wire; audio panning and effect placement
}

// Whether this kind is a detonation, which is the one question both the client
// (audio or effect?) and the server (how far does it carry?) have to ask.
event_is_blast :: proc(kind: Event_Kind) -> bool {
	return kind >= .He_Blast
}

// Well past what a full server produces: ten players running produce a step
// every ~19 ticks each, and even five on full auto add under one gunshot a
// tick. Four more than the old twelve, because a nade stack landing together
// must not push footsteps out. Overflow drops the tail.
MAX_WORLD_EVENTS :: 16

// Grenades in the air. Their own block rather than an entry in the entity
// array: Present_Mask indexes pawn ids, and a projectile is not a pawn.
//
// Always sent in full, like the bomb block and for the same reason -- there
// are rarely more than a handful, they change every tick while they fly, and
// delta machinery would cost more than the bytes it saved.
//
// Position is quantized to the centimetre. A grenade is 9 cm across and moves
// 30 cm in a tick; the rounding is far below what an eye following an arc can
// resolve, and nothing is decided by where a projectile *renders* -- the
// server owns the detonation.
Snapshot_Projectile :: struct {
	id:       u8, // slot index, stable for the projectile's life
	kind:     u8, // game.Grenade_Kind
	team_ct:  bool,
	position: [3]f32,
}

MAX_SNAPSHOT_PROJECTILES :: 16

// Smoke clouds and patches of fire. Sent to everyone unfiltered: a smoke is
// meant to be seen, and one you cannot see would still be one you walk into.
//
// The radius travels rather than being re-derived from an age the client would
// have to keep: it is one byte in decimetres, and it means the client's cloud
// is exactly the server's, including while it blooms.
Snapshot_Zone :: struct {
	id:       u8,
	kind:     u8, // game.Zone_Kind
	radius:   f32, // decimetres on the wire
	position: [3]f32, // quantized, like the projectiles
}

MAX_SNAPSHOT_ZONES :: 8

Snapshot :: struct {
	server_tick:     u32,
	baseline_tick:   u32, // 0 = delta against an empty world, i.e. full
	last_input_tick: u32, // newest client command applied before this tick
	phase:           game.Match_Phase,
	time_left:       f32, // seconds left in the phase; the fuse during .Bomb
	t_score:         u8,
	ct_score:        u8,
	// The bomb, always sent in full: continuous state that self-heals under
	// loss, and small enough (4 bytes, 16 while it lies somewhere) that delta
	// machinery would cost more than it saves. TDM sends state None.
	bomb_state:      game.Bomb_State,
	bomb_carrier:    u8, // pawn id, game.BOMB_NO_PAWN = nobody
	bomb_progress:   u8, // plant (Carried) or defuse (Planted) progress, 0..255
	bomb_defuser:    u8, // pawn id currently defusing, game.BOMB_NO_PAWN = nobody
	bomb_position:   [3]f32, // meaningful only when bomb_has_position(state)
	present:         Present_Mask,
	entities:        [game.MAX_PAWNS]Snapshot_Entity, // indexed by pawn id
	event_count:     u8,
	events:          [MAX_WORLD_EVENTS]World_Event,
	projectile_count: u8,
	projectiles:     [MAX_SNAPSHOT_PROJECTILES]Snapshot_Projectile,
	zone_count:      u8,
	zones:           [MAX_SNAPSHOT_ZONES]Snapshot_Zone,
	has_private:     bool,
	private:         Private_State,
}

// Appends one event, dropping it when the block is full. Returns whether it
// fit, so a caller that cares can log the loss rather than wonder.
snapshot_add_event :: proc(s: ^Snapshot, e: World_Event) -> bool {
	if s.event_count >= MAX_WORLD_EVENTS do return false
	s.events[s.event_count] = e
	s.event_count += 1
	return true
}

@(private = "file")
coarse_pitch :: proc(pitch: f32) -> u8 {
	return u8(quantize_pitch(pitch) >> 8) // 256 steps over 180 degrees
}

// Wire-space comparison; position by f32 bits, because -0.0 == 0.0 would let
// the two ends disagree about the stored value.
@(private = "file")
entity_field_mask :: proc(cur, base: ^Snapshot_Entity) -> (m: Field_Mask) {
	if cur.flags != base.flags do m += {.Flags}
	if transmute(u32)cur.position.x != transmute(u32)base.position.x do m += {.Pos_X}
	if transmute(u32)cur.position.y != transmute(u32)base.position.y do m += {.Pos_Y}
	if transmute(u32)cur.position.z != transmute(u32)base.position.z do m += {.Pos_Z}
	if quantize_yaw(cur.yaw) != quantize_yaw(base.yaw) do m += {.Yaw}
	if coarse_pitch(cur.pitch) != coarse_pitch(base.pitch) do m += {.Pitch}
	if cur.health != base.health do m += {.Health}
	if cur.weapon != base.weapon do m += {.Weapon}
	return
}

// `base` must be the snapshot named by s.baseline_tick exactly as the receiver
// stored it; pass a zeroed one for a full snapshot.
write_snapshot :: proc(w: ^Writer, s: Snapshot, base: ^Snapshot) {
	write_u32(w, s.server_tick)
	write_u32(w, s.baseline_tick)
	write_u32(w, s.last_input_tick)
	write_u8(w, u8(s.phase))
	// centiseconds in a u16 cover 10 minutes 55, far past any phase here
	write_u16(w, u16(clamp(s.time_left, 0, 600) * 100))
	write_u8(w, s.t_score)
	write_u8(w, s.ct_score)

	write_u8(w, u8(s.bomb_state))
	write_u8(w, s.bomb_carrier)
	write_u8(w, s.bomb_progress)
	write_u8(w, s.bomb_defuser)
	if game.bomb_has_position(s.bomb_state) {
		write_f32(w, s.bomb_position.x)
		write_f32(w, s.bomb_position.y)
		write_f32(w, s.bomb_position.z)
	}

	write_u16(w, transmute(u16)s.present)
	for i in 0 ..< game.MAX_PAWNS {
		if i not_in s.present do continue
		e := s.entities[i]
		// A pawn the baseline lacks is sent whole: diffing it against zeroes
		// would mask out every zero-valued field, and the receiver has no
		// unambiguous zero entity to build on.
		mask := FIELD_MASK_ALL
		if i in base.present {
			mask = entity_field_mask(&e, &base.entities[i])
		}
		write_u8(w, transmute(u8)mask)
		if .Flags in mask do write_u8(w, transmute(u8)e.flags)
		if .Pos_X in mask do write_f32(w, e.position.x)
		if .Pos_Y in mask do write_f32(w, e.position.y)
		if .Pos_Z in mask do write_f32(w, e.position.z)
		if .Yaw in mask do write_u16(w, quantize_yaw(e.yaw))
		if .Pitch in mask do write_u8(w, coarse_pitch(e.pitch))
		if .Health in mask do write_u8(w, e.health)
		if .Weapon in mask do write_u8(w, e.weapon)
	}

	// Sounds sit outside the delta machinery: every one is new, so a baseline
	// would have nothing to say about it.
	count := min(s.event_count, MAX_WORLD_EVENTS)
	write_u8(w, count)
	for i in 0 ..< int(count) {
		e := s.events[i]
		write_u8(w, u8(e.kind))
		write_u8(w, e.weapon)
		write_u16(w, transmute(u16)quantize_coarse_pos(e.position.x))
		write_u16(w, transmute(u16)quantize_coarse_pos(e.position.y))
		write_u16(w, transmute(u16)quantize_coarse_pos(e.position.z))
	}

	pcount := min(s.projectile_count, MAX_SNAPSHOT_PROJECTILES)
	write_u8(w, pcount)
	for i in 0 ..< int(pcount) {
		p := s.projectiles[i]
		write_u8(w, p.id)
		// Kind and side share a byte: four kinds and two teams have room to
		// spare, and the block is sent in full every tick.
		write_u8(w, p.kind | (p.team_ct ? 0x80 : 0))
		write_u16(w, transmute(u16)quantize_coarse_pos(p.position.x))
		write_u16(w, transmute(u16)quantize_coarse_pos(p.position.y))
		write_u16(w, transmute(u16)quantize_coarse_pos(p.position.z))
	}

	zcount := min(s.zone_count, MAX_SNAPSHOT_ZONES)
	write_u8(w, zcount)
	for i in 0 ..< int(zcount) {
		z := s.zones[i]
		write_u8(w, z.id)
		write_u8(w, z.kind)
		// Decimetres: a cloud is metres across and nothing is decided by the
		// centimetre, so one byte covers 25 m with room to spare.
		write_u8(w, u8(clamp(z.radius * 10, 0, 255)))
		write_u16(w, transmute(u16)quantize_coarse_pos(z.position.x))
		write_u16(w, transmute(u16)quantize_coarse_pos(z.position.y))
		write_u16(w, transmute(u16)quantize_coarse_pos(z.position.z))
	}

	write_u8(w, s.has_private ? 1 : 0)
	if s.has_private {
		p := s.private
		write_f32(w, p.velocity.x)
		write_f32(w, p.velocity.y)
		write_f32(w, p.velocity.z)
		write_u8(w, p.armor)
		write_u8(w, transmute(u8)p.gear)
		write_u8(w, p.ammo_mag)
		write_u8(w, p.ammo_reserve)
		write_u8(w, p.cooldown_ticks)
		write_u8(w, p.reload_ticks)
		write_u8(w, p.kills)
		write_u8(w, p.deaths)
		write_u8(w, p.spray_progress)
		write_u32(w, p.spray_seed)
		write_u16(w, p.money)
		write_u16(w, p.flash_left_cs)
		write_u16(w, p.flash_total_cs)
		for held in p.grenades do write_u8(w, held)
		write_u8(w, transmute(u8)p.hand)
	}
}

// The delta is self-describing -- present mask and field masks fully determine
// the byte layout -- so it parses against any baseline; the baseline only
// supplies the values of unchanged fields.
read_snapshot :: proc(r: ^Reader, base: ^Snapshot) -> (s: Snapshot, ok: bool) {
	s.server_tick = read_u32(r)
	s.baseline_tick = read_u32(r)
	s.last_input_tick = read_u32(r)
	s.phase = game.Match_Phase(read_u8(r))
	s.time_left = f32(read_u16(r)) / 100
	s.t_score = read_u8(r)
	s.ct_score = read_u8(r)

	s.bomb_state = game.Bomb_State(read_u8(r))
	s.bomb_carrier = read_u8(r)
	s.bomb_progress = read_u8(r)
	s.bomb_defuser = read_u8(r)
	if game.bomb_has_position(s.bomb_state) {
		s.bomb_position.x = read_f32(r)
		s.bomb_position.y = read_f32(r)
		s.bomb_position.z = read_f32(r)
	}

	s.present = transmute(Present_Mask)read_u16(r)
	for i in 0 ..< game.MAX_PAWNS {
		if i not_in s.present do continue
		e := &s.entities[i]
		if i in base.present {
			e^ = base.entities[i]
		}
		mask := transmute(Field_Mask)read_u8(r)
		if .Flags in mask do e.flags = transmute(Entity_Flags)read_u8(r)
		if .Pos_X in mask do e.position.x = read_f32(r)
		if .Pos_Y in mask do e.position.y = read_f32(r)
		if .Pos_Z in mask do e.position.z = read_f32(r)
		if .Yaw in mask do e.yaw = dequantize_yaw(read_u16(r))
		if .Pitch in mask do e.pitch = dequantize_pitch(u16(read_u8(r)) << 8)
		if .Health in mask do e.health = read_u8(r)
		if .Weapon in mask do e.weapon = read_u8(r)
	}

	// A corrupt count must not walk the reader off the end; the reader flags
	// its own overruns, but clamping keeps the loop bounded either way.
	s.event_count = min(read_u8(r), MAX_WORLD_EVENTS)
	for i in 0 ..< int(s.event_count) {
		e := &s.events[i]
		e.kind = Event_Kind(read_u8(r))
		e.weapon = read_u8(r)
		e.position.x = dequantize_coarse_pos(transmute(i16)read_u16(r))
		e.position.y = dequantize_coarse_pos(transmute(i16)read_u16(r))
		e.position.z = dequantize_coarse_pos(transmute(i16)read_u16(r))
	}

	s.projectile_count = min(read_u8(r), MAX_SNAPSHOT_PROJECTILES)
	for i in 0 ..< int(s.projectile_count) {
		p := &s.projectiles[i]
		p.id = read_u8(r)
		packed := read_u8(r)
		p.kind = packed & 0x7F
		p.team_ct = packed & 0x80 != 0
		p.position.x = dequantize_coarse_pos(transmute(i16)read_u16(r))
		p.position.y = dequantize_coarse_pos(transmute(i16)read_u16(r))
		p.position.z = dequantize_coarse_pos(transmute(i16)read_u16(r))
	}

	s.zone_count = min(read_u8(r), MAX_SNAPSHOT_ZONES)
	for i in 0 ..< int(s.zone_count) {
		z := &s.zones[i]
		z.id = read_u8(r)
		z.kind = read_u8(r)
		z.radius = f32(read_u8(r)) / 10
		z.position.x = dequantize_coarse_pos(transmute(i16)read_u16(r))
		z.position.y = dequantize_coarse_pos(transmute(i16)read_u16(r))
		z.position.z = dequantize_coarse_pos(transmute(i16)read_u16(r))
	}

	s.has_private = read_u8(r) != 0
	if s.has_private {
		p := &s.private
		p.velocity.x = read_f32(r)
		p.velocity.y = read_f32(r)
		p.velocity.z = read_f32(r)
		p.armor = read_u8(r)
		p.gear = transmute(Private_Gear_Flags)read_u8(r)
		p.ammo_mag = read_u8(r)
		p.ammo_reserve = read_u8(r)
		p.cooldown_ticks = read_u8(r)
		p.reload_ticks = read_u8(r)
		p.kills = read_u8(r)
		p.deaths = read_u8(r)
		p.spray_progress = read_u8(r)
		p.spray_seed = read_u32(r)
		p.money = read_u16(r)
		p.flash_left_cs = read_u16(r)
		p.flash_total_cs = read_u16(r)
		for i in 0 ..< game.GRENADE_COUNT do p.grenades[i] = read_u8(r)
		p.hand = transmute(i8)read_u8(r)
	}
	return s, !r.error
}
