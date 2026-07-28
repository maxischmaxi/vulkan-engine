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
Private_State :: struct {
	velocity:       [3]f32,
	armor:          u8,
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
}

Snapshot :: struct {
	server_tick:     u32,
	baseline_tick:   u32, // 0 = delta against an empty world, i.e. full
	last_input_tick: u32, // newest client command applied before this tick
	phase:           game.Match_Phase,
	time_left:       f32, // seconds left in the phase
	t_score:         u8,
	ct_score:        u8,
	present:         Present_Mask,
	entities:        [game.MAX_PAWNS]Snapshot_Entity, // indexed by pawn id
	has_private:     bool,
	private:         Private_State,
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

	write_u8(w, s.has_private ? 1 : 0)
	if s.has_private {
		p := s.private
		write_f32(w, p.velocity.x)
		write_f32(w, p.velocity.y)
		write_f32(w, p.velocity.z)
		write_u8(w, p.armor)
		write_u8(w, p.ammo_mag)
		write_u8(w, p.ammo_reserve)
		write_u8(w, p.cooldown_ticks)
		write_u8(w, p.reload_ticks)
		write_u8(w, p.kills)
		write_u8(w, p.deaths)
		write_u8(w, p.spray_progress)
		write_u32(w, p.spray_seed)
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

	s.has_private = read_u8(r) != 0
	if s.has_private {
		p := &s.private
		p.velocity.x = read_f32(r)
		p.velocity.y = read_f32(r)
		p.velocity.z = read_f32(r)
		p.armor = read_u8(r)
		p.ammo_mag = read_u8(r)
		p.ammo_reserve = read_u8(r)
		p.cooldown_ticks = read_u8(r)
		p.reload_ticks = read_u8(r)
		p.kills = read_u8(r)
		p.deaths = read_u8(r)
		p.spray_progress = read_u8(r)
		p.spray_seed = read_u32(r)
	}
	return s, !r.error
}
