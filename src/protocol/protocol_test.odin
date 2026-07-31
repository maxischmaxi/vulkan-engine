package protocol

import "../game"
import "core:testing"

// The wire format is only as trustworthy as its roundtrips: everything that
// goes out must come back bit-equal (or, for quantized angles, within one
// step), and the reliability window must deliver exactly once and in order no
// matter which packets die on the way.

@(test)
test_primitive_roundtrip :: proc(t: ^testing.T) {
	buf: [64]u8
	w := writer(buf[:])
	write_u8(&w, 0xAB)
	write_u16(&w, 0xBEEF)
	write_u32(&w, 0xDEADBEEF)
	write_f32(&w, -123.456)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	testing.expect_value(t, read_u8(&r), u8(0xAB))
	testing.expect_value(t, read_u16(&r), u16(0xBEEF))
	testing.expect_value(t, read_u32(&r), u32(0xDEADBEEF))
	testing.expect_value(t, read_f32(&r), f32(-123.456))
	testing.expect(t, !r.error)

	// one more read runs off the end and must flag, not crash
	read_u32(&r)
	testing.expect(t, r.error)
}

@(test)
test_writer_overflow_sticky :: proc(t: ^testing.T) {
	buf: [3]u8
	w := writer(buf[:])
	write_u32(&w, 1)
	testing.expect(t, w.overflow)
	write_u8(&w, 1) // must not panic after overflow
	testing.expect(t, w.overflow)
}

@(test)
test_connect_request_roundtrip :: proc(t: ^testing.T) {
	for tlen in ([]int{0, 234, MAX_TICKET}) {
		m: Connect_Request
		m.client_salt = 0xC0FFEE
		m.name_len = u8(copy(m.name[:], "PLAYER"))
		m.ticket_len = u16(tlen)
		for i in 0 ..< tlen do m.ticket[i] = u8(i * 7)

		buf: [2 * MAX_TICKET]u8
		w := writer(buf[:])
		write_connect_request(&w, m)
		testing.expect(t, !w.overflow)
		// the worst case must still fit one unfragmented datagram
		testing.expect(t, HEADER_SIZE + 1 + w.off <= MTU)

		r := reader(buf[:w.off])
		back, ok := read_connect_request(&r)
		testing.expect(t, ok)
		testing.expect_value(t, back.client_salt, m.client_salt)
		testing.expect_value(t, back.name_len, m.name_len)
		testing.expect_value(t, back.ticket_len, m.ticket_len)
		testing.expect(t, back.name == m.name)
		testing.expect(t, back.ticket == m.ticket)
	}

	// a ticket that cannot fit the buffer must flag overflow, not crash
	m: Connect_Request
	m.ticket_len = MAX_TICKET
	small: [128]u8
	w := writer(small[:])
	write_connect_request(&w, m)
	testing.expect(t, w.overflow)

	// a truncated datagram must flag a read error, not crash
	big: [2 * MAX_TICKET]u8
	w2 := writer(big[:])
	write_connect_request(&w2, m)
	r := reader(big[:w2.off - 10])
	_, ok := read_connect_request(&r)
	testing.expect(t, !ok)
}

@(test)
test_yaw_quantization :: proc(t: ^testing.T) {
	step := f32(360.0 / 65536.0)
	for yaw in ([]f32{0, 90, 179.9, -180, -10, 359.9, 720.5}) {
		q := quantize_yaw(yaw)
		back := dequantize_yaw(q)
		// compare on the circle: wrap the input the same way
		wrapped := yaw
		for wrapped < 0 do wrapped += 360
		for wrapped >= 360 do wrapped -= 360
		diff := abs(back - wrapped)
		if diff > 180 do diff = 360 - diff
		testing.expect(t, diff <= step, "yaw roundtrip off by more than one step")
	}
	// the roundtrip must be stable: quantizing a dequantized value is identity
	q := quantize_yaw(123.456)
	testing.expect_value(t, quantize_yaw(dequantize_yaw(q)), q)
}

@(test)
test_pitch_quantization :: proc(t: ^testing.T) {
	step := f32(180.0 / 65535.0)
	for pitch in ([]f32{0, 45, -45, 89, -89}) {
		back := dequantize_pitch(quantize_pitch(pitch))
		testing.expect(t, abs(back - pitch) <= step)
	}
	// out-of-range pitches clamp to the playable range
	testing.expect(t, abs(dequantize_pitch(quantize_pitch(200)) - 89) <= step)
	testing.expect(t, abs(dequantize_pitch(quantize_pitch(-200)) + 89) <= step)
}

@(test)
test_input_roundtrip :: proc(t: ^testing.T) {
	m: Input_Msg
	m.last_snapshot_tick = 977
	m.newest_tick = 1000
	m.count = 3
	for i in 0 ..< 3 {
		m.commands[i] = {
			buttons     = {.Forward, .Jump} if i == 0 else {.Fire},
			yaw         = f32(i) * 10.5,
			pitch       = f32(i) - 1,
			weapon_slot = i8(i - 1),
		}
	}

	buf: [256]u8
	w := writer(buf[:])
	write_input(&w, m)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	got, ok := read_input(&r)
	testing.expect(t, ok)
	testing.expect_value(t, got.last_snapshot_tick, m.last_snapshot_tick)
	testing.expect_value(t, got.newest_tick, m.newest_tick)
	testing.expect_value(t, got.count, m.count)
	for i in 0 ..< 3 {
		testing.expect_value(t, got.commands[i].buttons, m.commands[i].buttons)
		testing.expect_value(t, got.commands[i].weapon_slot, m.commands[i].weapon_slot)
		// angles come back as their wire values
		wy, wp := wire_angles(m.commands[i].yaw, m.commands[i].pitch)
		testing.expect_value(t, got.commands[i].yaw, wy)
		testing.expect_value(t, got.commands[i].pitch, wp)
	}
}

@(test)
test_damage_roundtrip :: proc(t: ^testing.T) {
	step := f32(360.0 / 65536.0)
	for direction in ([]f32{0, 90.5, 271.25, -45}) {
		m := Damage_Msg {
			tick      = 123456,
			direction = direction,
			amount    = 23,
		}
		buf: [16]u8
		w := writer(buf[:])
		write_damage(&w, m)
		testing.expect(t, !w.overflow)
		testing.expect_value(t, w.off, 7)

		r := reader(buf[:w.off])
		got, ok := read_damage(&r)
		testing.expect(t, ok)
		testing.expect_value(t, got.tick, m.tick)
		testing.expect_value(t, got.amount, m.amount)
		// the angle comes back wrapped onto [0, 360), within one quantizer step
		wrapped := direction
		for wrapped < 0 do wrapped += 360
		diff := abs(got.direction - wrapped)
		if diff > 180 do diff = 360 - diff
		testing.expect(t, diff <= step, "damage direction off by more than one step")
	}
}

// header 17 + bomb block 4 + present 2: the fixed cost of every snapshot on
// the wire (a dropped or planted bomb adds its 12-byte position)
SNAP_FIXED_BYTES :: 23

@(test)
test_snapshot_roundtrip :: proc(t: ^testing.T) {
	s: Snapshot
	s.server_tick = 4242
	s.last_input_tick = 4200
	s.phase = .Live
	s.time_left = 42.5
	s.t_score = 3
	s.ct_score = 5
	s.present = {0, 3}
	s.entities[0] = {
		flags    = {.Alive, .On_Ground},
		position = {1.5, -2.5, 0.25},
		yaw      = 90,
		health   = 77,
		weapon   = 1,
	}
	s.entities[3] = {
		flags    = {.Alive, .Is_Bot, .Team_CT, .Fired},
		position = {-40, 12, 1.6},
		yaw      = 271.25,
		health   = 100,
	}
	s.has_private = true
	s.private = {
		velocity       = {1, 2, -3},
		armor          = 88,
		ammo_mag       = 17,
		ammo_reserve   = 90,
		kills          = 4,
		deaths         = 2,
		spray_progress = 44, // 5.5 shots deep, in eighths
		spray_seed     = 0xDEAD_BEEF,
	}

	zero: Snapshot
	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, s, &zero)
	testing.expect(t, !w.overflow)
	// full: fixed + 2 x (mask 1 + fields 18) + has_private 1 + private 26
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 2 * 19 + 1 + 26)

	r := reader(buf[:w.off])
	got, ok := read_snapshot(&r, &zero)
	testing.expect(t, ok)
	testing.expect_value(t, got.server_tick, s.server_tick)
	testing.expect_value(t, got.last_input_tick, s.last_input_tick)
	testing.expect_value(t, got.phase, s.phase)
	testing.expect_value(t, got.time_left, s.time_left)
	testing.expect_value(t, got.present, s.present)
	testing.expect_value(t, got.entities[3].flags, s.entities[3].flags)
	testing.expect_value(t, got.entities[3].position, s.entities[3].position)
	testing.expect_value(t, got.entities[0].health, s.entities[0].health)
	testing.expect(t, got.has_private)
	testing.expect_value(t, got.private.velocity, s.private.velocity)
	testing.expect_value(t, got.private.kills, s.private.kills)
	testing.expect_value(t, got.private.spray_progress, s.private.spray_progress)
	testing.expect_value(t, got.private.spray_seed, s.private.spray_seed)
}

// A changed subset travels; everything else comes out of the receiver's
// baseline -- including a yaw whose raw floats differ but whose wire value
// does not.
@(test)
test_snapshot_delta_subset :: proc(t: ^testing.T) {
	server_base: Snapshot
	server_base.server_tick = 100
	server_base.present = {2}
	server_base.entities[2] = {
		flags    = {.Alive},
		position = {10, 20, 0.5},
		yaw      = 123.456,
		pitch    = 10,
		health   = 100,
		weapon   = 1,
	}

	// what the client actually stored: the baseline after one wire roundtrip
	zero: Snapshot
	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, server_base, &zero)
	r := reader(buf[:w.off])
	client_base, bok := read_snapshot(&r, &zero)
	testing.expect(t, bok)

	cur := server_base
	cur.server_tick = 101
	cur.baseline_tick = 100
	cur.entities[2].position.x = 11.5 // moved east
	cur.entities[2].health = 80 // and got shot
	cur.entities[2].pitch = 10.1 // below one coarse step: must not travel

	w = writer(buf[:])
	write_snapshot(&w, cur, &server_base)
	// fixed + mask 1 + pos_x 4 + health 1
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 1 + 4 + 1 + 1)

	r = reader(buf[:w.off])
	got, ok := read_snapshot(&r, &client_base)
	testing.expect(t, ok)
	testing.expect_value(t, got.entities[2].position.x, f32(11.5))
	testing.expect_value(t, got.entities[2].health, u8(80))
	// unchanged fields are the client's stored wire values, bit for bit
	testing.expect_value(t, got.entities[2].position.y, f32(20))
	testing.expect_value(t, got.entities[2].yaw, client_base.entities[2].yaw)
	testing.expect_value(t, got.entities[2].pitch, client_base.entities[2].pitch)
	testing.expect_value(t, got.entities[2].flags, client_base.entities[2].flags)
}

@(test)
test_snapshot_unchanged_entity_costs_one_byte :: proc(t: ^testing.T) {
	base: Snapshot
	base.present = {5}
	base.entities[5] = {
		flags    = {.Alive, .Is_Bot},
		position = {1, 2, 3},
		yaw      = 42,
		health   = 100,
	}

	cur := base
	cur.baseline_tick = 1

	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, cur, &base)
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 1 + 1) // empty mask, no private
}

// A pawn the baseline lacks travels whole, even where its fields happen to
// equal the zero struct -- the receiver has no zero entity to build on.
@(test)
test_snapshot_appearing_entity_sent_full :: proc(t: ^testing.T) {
	base: Snapshot
	base.server_tick = 50
	base.present = {} // empty world acked

	cur: Snapshot
	cur.server_tick = 51
	cur.baseline_tick = 50
	cur.present = {1}
	cur.entities[1] = {
		flags    = {}, // dead T pawn: flags byte is zero
		position = {0, 0, 0},
		health   = 0,
		weapon   = 0,
	}

	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, cur, &base)
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 1 + 18 + 1)

	r := reader(buf[:w.off])
	got, ok := read_snapshot(&r, &base)
	testing.expect(t, ok)
	testing.expect_value(t, got.present, Present_Mask{1})
	testing.expect_value(t, got.entities[1].position, [3]f32{0, 0, 0})
	testing.expect_value(t, got.entities[1].health, u8(0))
}

@(test)
test_snapshot_disappearing_entity :: proc(t: ^testing.T) {
	base: Snapshot
	base.present = {1, 2}
	base.entities[1].health = 50
	base.entities[2].health = 60

	cur := base
	cur.baseline_tick = 7
	cur.present = {2}

	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, cur, &base)
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 1 + 1) // pawn 2 unchanged

	r := reader(buf[:w.off])
	got, ok := read_snapshot(&r, &base)
	testing.expect(t, ok)
	testing.expect_value(t, got.present, Present_Mask{2})
	testing.expect_value(t, got.entities[2].health, u8(60))
}

// -0.0 == 0.0 as floats, but not as stored bits: the comparison must be
// bitwise or the two ends drift apart about what the baseline holds.
@(test)
test_snapshot_negative_zero_position_travels :: proc(t: ^testing.T) {
	base: Snapshot
	base.present = {0}
	base.entities[0].position = {0, 1, 2}

	cur := base
	cur.baseline_tick = 3
	neg_zero := transmute(f32)u32(0x8000_0000)
	cur.entities[0].position.x = neg_zero

	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, cur, &base)
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 1 + 4 + 1)

	r := reader(buf[:w.off])
	got, ok := read_snapshot(&r, &base)
	testing.expect(t, ok)
	testing.expect_value(t, transmute(u32)got.entities[0].position.x, u32(0x8000_0000))
}

@(test)
test_debug_flags_roundtrip :: proc(t: ^testing.T) {
	for m in ([]Debug_Flags{{}, {god = true}, {infinite_ammo = true}, {true, true}}) {
		buf: [8]u8
		w := writer(buf[:])
		write_debug_flags(&w, m)
		r := reader(buf[:w.off])
		got, ok := read_debug_flags(&r)
		testing.expect(t, ok)
		testing.expect_value(t, got, m)
	}
}

@(test)
test_loadout_roundtrip :: proc(t: ^testing.T) {
	for m in ([]Loadout_Msg {
			{primary = -1, secondary = 1, armor = false},
			{primary = 9, secondary = 3, armor = true},
		}) {
		buf: [8]u8
		w := writer(buf[:])
		write_loadout(&w, m)
		testing.expect_value(t, w.off, 3)
		r := reader(buf[:w.off])
		got, ok := read_loadout(&r)
		testing.expect(t, ok)
		testing.expect_value(t, got, m)
	}
}

@(test)
test_practice_roundtrip :: proc(t: ^testing.T) {
	for m in ([]Practice_Msg{{entering = true}, {entering = false}}) {
		buf: [8]u8
		w := writer(buf[:])
		write_practice(&w, m)
		testing.expect_value(t, w.off, 1)
		r := reader(buf[:w.off])
		got, ok := read_practice(&r)
		testing.expect(t, ok)
		testing.expect_value(t, got, m)
	}
}

@(test)
test_join_deny_roundtrip :: proc(t: ^testing.T) {
	for reason in ([]Join_Deny_Reason{.None, .Teams_Full, .Between_Matches}) {
		buf: [8]u8
		w := writer(buf[:])
		write_join_deny(&w, Join_Deny_Msg{reason = reason})
		testing.expect_value(t, w.off, 1)
		r := reader(buf[:w.off])
		got, ok := read_join_deny(&r)
		testing.expect(t, ok)
		testing.expect_value(t, got.reason, reason)
	}
}

@(test)
test_roster_roundtrip :: proc(t: ^testing.T) {
	m: Roster
	m.count = 3
	m.entries[0] = {
		pawn_id = 0,
		kills   = 7,
		deaths  = 2,
	}
	m.entries[0].name_len = u8(copy(m.entries[0].name[:], "ALICE"))
	m.entries[1] = {
		pawn_id = 4,
		kills   = 1,
		deaths  = 9,
	} // a bot: empty name
	m.entries[2] = {
		pawn_id = 15,
		kills   = 0,
		deaths  = 0,
	}
	m.entries[2].name_len = u8(copy(m.entries[2].name[:], "SIXTEEN CHAR NAME"))

	buf: [MTU]u8
	w := writer(buf[:])
	write_roster(&w, m)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	got, ok := read_roster(&r)
	testing.expect(t, ok)
	testing.expect_value(t, got.count, m.count)
	for i in 0 ..< int(m.count) {
		testing.expect_value(t, got.entries[i].pawn_id, m.entries[i].pawn_id)
		testing.expect_value(t, got.entries[i].kills, m.entries[i].kills)
		testing.expect_value(t, got.entries[i].deaths, m.entries[i].deaths)
		testing.expect_value(t, got.entries[i].name_len, m.entries[i].name_len)
		testing.expect(t, got.entries[i].name == m.entries[i].name)
	}
}

// Every chunk must clear the reliable slot even when all names run full --
// the case that used to overflow queue_reliable_msg and drop clients.
@(test)
test_roster_chunk_split_full_names :: proc(t: ^testing.T) {
	full: Roster
	full.count = u8(game.MAX_PAWNS)
	for i in 0 ..< game.MAX_PAWNS {
		e := &full.entries[i]
		e.pawn_id = u8(i)
		e.kills = u8(i * 2)
		e.deaths = u8(i)
		e.name_len = MAX_NAME
		for j in 0 ..< MAX_NAME do e.name[j] = u8('A' + i)
	}

	chunks: [MAX_ROSTER_CHUNKS]Roster
	n := roster_chunk_split(full, chunks[:])
	testing.expect_value(t, n, 6) // 3 full-name entries a chunk

	// merge back in order and compare every entry
	merged: Roster
	for c in 0 ..< n {
		buf: [MAX_RELIABLE_PAYLOAD]u8
		w := writer(buf[:])
		write_roster(&w, chunks[c])
		testing.expect(t, !w.overflow, "chunk must fit the reliable slot")

		r := reader(buf[:w.off])
		got, ok := read_roster(&r)
		testing.expect(t, ok)
		for i in 0 ..< int(got.count) {
			merged.entries[merged.count] = got.entries[i]
			merged.count += 1
		}
	}
	testing.expect_value(t, merged.count, full.count)
	for i in 0 ..< int(full.count) {
		testing.expect_value(t, merged.entries[i].pawn_id, full.entries[i].pawn_id)
		testing.expect_value(t, merged.entries[i].kills, full.entries[i].kills)
		testing.expect(t, merged.entries[i].name == full.entries[i].name)
	}
}

// Bot entries carry no name bytes, so they pack far tighter.
@(test)
test_roster_chunk_split_bots_pack_tight :: proc(t: ^testing.T) {
	full: Roster
	full.count = u8(game.MAX_PAWNS)
	for i in 0 ..< game.MAX_PAWNS {
		e := &full.entries[i]
		e.pawn_id = u8(i)
		if i < 2 {
			e.name_len = MAX_NAME
			for j in 0 ..< MAX_NAME do e.name[j] = u8('H')
		}
	}

	chunks: [MAX_ROSTER_CHUNKS]Roster
	n := roster_chunk_split(full, chunks[:])
	testing.expect_value(t, n, 2) // 2 humans + 5 bots, then 9 bots

	total := 0
	for c in 0 ..< n {
		buf: [MAX_RELIABLE_PAYLOAD]u8
		w := writer(buf[:])
		write_roster(&w, chunks[c])
		testing.expect(t, !w.overflow)
		total += int(chunks[c].count)
	}
	testing.expect_value(t, total, int(full.count))
}

@(test)
test_roster_chunk_split_empty :: proc(t: ^testing.T) {
	full: Roster
	chunks: [MAX_ROSTER_CHUNKS]Roster
	testing.expect_value(t, roster_chunk_split(full, chunks[:]), 0)
}

@(test)
test_seq_greater_wraps :: proc(t: ^testing.T) {
	testing.expect(t, seq_greater(1, 0))
	testing.expect(t, !seq_greater(0, 1))
	testing.expect(t, !seq_greater(5, 5))
	// the wrap: 0 is newer than 65535
	testing.expect(t, seq_greater(0, 65535))
	testing.expect(t, !seq_greater(65535, 0))
	testing.expect(t, seq_greater(32767, 0))
	testing.expect(t, !seq_greater(32768, 0))
}

// A little harness: one side emits a packet, the other eats it.
@(private = "file")
exchange :: proc(from, to: ^Connection, drop: bool) -> (delivered: int, ok: bool) {
	buf: [MTU]u8
	w := writer(buf[:])
	connection_begin_packet(from, &w)
	if drop do return 0, true

	_, read_ok := connection_read(to, buf[:w.off])
	return to.incoming_count, read_ok
}

@(test)
test_reliable_in_order_delivery :: proc(t: ^testing.T) {
	a, b: Connection
	connection_init(&a, 7)
	connection_init(&b, 7)

	testing.expect(t, queue_reliable(&a, .Join, {1}))
	testing.expect(t, queue_reliable(&a, .Match_Phase, {2, 0, 0, 0, 0, 1, 3}))
	testing.expect(t, queue_reliable(&a, .Kill, {0, 3, 1}))

	delivered, ok := exchange(&a, &b, false)
	testing.expect(t, ok)
	testing.expect_value(t, delivered, 3)
	testing.expect_value(t, b.incoming[0].msg_id, Msg_Id.Join)
	testing.expect_value(t, b.incoming[1].msg_id, Msg_Id.Match_Phase)
	testing.expect_value(t, b.incoming[2].msg_id, Msg_Id.Kill)
	testing.expect_value(t, b.incoming[2].payload[1], u8(3))

	// the ack rides back on B's next packet and frees A's window
	_, ok = exchange(&b, &a, false)
	testing.expect(t, ok)
	testing.expect_value(t, a.rel_acked, a.rel_next)
}

@(test)
test_reliable_survives_loss_and_delivers_once :: proc(t: ^testing.T) {
	a, b: Connection
	connection_init(&a, 9)
	connection_init(&b, 9)

	testing.expect(t, queue_reliable(&a, .Join, {1}))

	// first packet dies on the wire
	delivered, _ := exchange(&a, &b, true)
	testing.expect_value(t, delivered, 0)

	// the next packet re-carries the window: delivered exactly here
	ok: bool
	delivered, ok = exchange(&a, &b, false)
	testing.expect(t, ok)
	testing.expect_value(t, delivered, 1)

	// a third packet before any ack still carries it -- as a duplicate, dropped
	delivered, ok = exchange(&a, &b, false)
	testing.expect(t, ok)
	testing.expect_value(t, delivered, 0)
}

@(test)
test_stale_packets_dropped :: proc(t: ^testing.T) {
	a, b: Connection
	connection_init(&a, 5)
	connection_init(&b, 5)

	one: [MTU]u8
	w1 := writer(one[:])
	connection_begin_packet(&a, &w1)
	two: [MTU]u8
	w2 := writer(two[:])
	connection_begin_packet(&a, &w2)

	// reordered on the wire: the newer packet lands first
	_, ok := connection_read(&b, two[:w2.off])
	testing.expect(t, ok)
	_, ok = connection_read(&b, one[:w1.off])
	testing.expect(t, !ok)
}

@(test)
test_wrong_session_dropped :: proc(t: ^testing.T) {
	a, b: Connection
	connection_init(&a, 11)
	connection_init(&b, 12)

	buf: [MTU]u8
	w := writer(buf[:])
	connection_begin_packet(&a, &w)
	_, ok := connection_read(&b, buf[:w.off])
	testing.expect(t, !ok)
}

@(test)
test_reliable_window_full :: proc(t: ^testing.T) {
	a: Connection
	connection_init(&a, 1)
	for i in 0 ..< RELIABLE_WINDOW {
		testing.expect(t, queue_reliable(&a, .Kill, {u8(i), 0, 0}))
	}
	testing.expect(t, !queue_reliable(&a, .Kill, {0, 0, 0}))
}

@(test)
test_queue_reliable_msg_serializes :: proc(t: ^testing.T) {
	a, b: Connection
	connection_init(&a, 2)
	connection_init(&b, 2)

	testing.expect(
		t,
		queue_reliable_msg(
			&a,
			.Match_Phase,
			write_match_phase,
			Match_Phase_Msg {
				phase = .Round_End,
				param_tick = 3840,
				t_score = 7,
				ct_score = 9,
				round = 17,
				winner = u8(game.Team.CT),
				reason = .Bomb_Defused,
			},
		),
	)

	delivered, ok := exchange(&a, &b, false)
	testing.expect(t, ok)
	testing.expect_value(t, delivered, 1)

	slot := b.incoming[0]
	r := reader(slot.payload[:slot.size])
	m, mok := read_match_phase(&r)
	testing.expect(t, mok)
	testing.expect_value(t, m.phase, game.Match_Phase.Round_End)
	testing.expect_value(t, m.param_tick, u32(3840))
	testing.expect_value(t, m.t_score, u8(7))
	testing.expect_value(t, m.ct_score, u8(9))
	testing.expect_value(t, m.round, u8(17))
	testing.expect_value(t, m.winner, u8(game.Team.CT))
	testing.expect_value(t, m.reason, game.Round_End_Reason.Bomb_Defused)
}

// The bomb block: four flat bytes normally, the position only while the bomb
// lies somewhere -- and the reader must key that off the state alone.
@(test)
test_snapshot_bomb_block :: proc(t: ^testing.T) {
	s: Snapshot
	s.server_tick = 7
	s.bomb_state = .Planted
	s.bomb_carrier = game.BOMB_NO_PAWN
	s.bomb_progress = 128
	s.bomb_defuser = 3
	s.bomb_position = {22.5, 31, 1.4}

	zero: Snapshot
	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, s, &zero)
	testing.expect(t, !w.overflow)
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 12 + 1) // + position + no private

	r := reader(buf[:w.off])
	got, ok := read_snapshot(&r, &zero)
	testing.expect(t, ok)
	testing.expect_value(t, got.bomb_state, game.Bomb_State.Planted)
	testing.expect_value(t, got.bomb_carrier, game.BOMB_NO_PAWN)
	testing.expect_value(t, got.bomb_progress, u8(128))
	testing.expect_value(t, got.bomb_defuser, u8(3))
	testing.expect_value(t, got.bomb_position, [3]f32{22.5, 31, 1.4})

	// carried: no position bytes
	s.bomb_state = .Carried
	s.bomb_carrier = 2
	w = writer(buf[:])
	write_snapshot(&w, s, &zero)
	testing.expect_value(t, w.off, SNAP_FIXED_BYTES + 1)
	r = reader(buf[:w.off])
	got, ok = read_snapshot(&r, &zero)
	testing.expect(t, ok)
	testing.expect_value(t, got.bomb_state, game.Bomb_State.Carried)
	testing.expect_value(t, got.bomb_carrier, u8(2))
	testing.expect_value(t, got.bomb_position, [3]f32{})
}

// The worst snapshot the wire can carry: every pawn present and sent full,
// the bomb lying somewhere, the private block attached. Must clear the MTU
// with room to spare.
@(test)
test_snapshot_worst_case_fits_mtu :: proc(t: ^testing.T) {
	s: Snapshot
	s.bomb_state = .Planted
	s.bomb_position = {1, 2, 3}
	s.has_private = true
	for i in 0 ..< game.MAX_PAWNS {
		s.present += {i}
		s.entities[i] = {
			flags    = {.Alive, .Fired},
			position = {f32(i) * 3.3, -f32(i), 1.5},
			yaw      = f32(i) * 20,
			pitch    = 45,
			health   = 100,
			weapon   = u8(i % 10),
		}
	}

	zero: Snapshot
	buf: [MTU]u8
	w := writer(buf[:])
	write_snapshot(&w, s, &zero)
	testing.expect(t, !w.overflow)
	testing.expect(t, w.off < MTU / 2, "worst-case snapshot should stay far below the MTU")

	r := reader(buf[:w.off])
	got, ok := read_snapshot(&r, &zero)
	testing.expect(t, ok)
	testing.expect_value(t, got.present, s.present)
	testing.expect_value(t, got.private.money, s.private.money)
}
