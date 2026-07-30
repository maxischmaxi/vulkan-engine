package mm

import "core:testing"

// Roundtrips in the protocol_test.odin tradition: everything written must come
// back bit-equal, truncated datagrams must flag instead of crash, and the
// frame must reject foreign magic.

@(test)
test_frame_roundtrip :: proc(t: ^testing.T) {
	buf: [MM_MAX_DATAGRAM]u8
	w := writer(buf[:])
	frame_begin(&w, .Find_Server)
	testing.expect(t, !w.overflow)

	r, msg, ok := frame_open(buf[:w.off])
	testing.expect(t, ok)
	testing.expect_value(t, msg, Mm_Msg.Find_Server)
	testing.expect(t, !r.error)
}

@(test)
test_frame_rejects_foreign_magic :: proc(t: ^testing.T) {
	// game-protocol magic must not open as a control frame
	buf := [4]u8{0xF5, 0xB0, 9, 1}
	_, msg, ok := frame_open(buf[:])
	testing.expect(t, !ok)
	testing.expect_value(t, msg, Mm_Msg.Invalid)

	// and a datagram shorter than the frame flags, not crashes
	_, _, ok2 := frame_open(buf[:2])
	testing.expect(t, !ok2)
}

@(test)
test_server_heartbeat_roundtrip :: proc(t: ^testing.T) {
	m: Server_Heartbeat
	m.token = token_from_string("secret")
	m.server_id = 0xDEAD_BEEF_CAFE_F00D
	m.spawn_id = 42
	m.region = region_from_string("eu")
	m.addr = {
		kind     = .Steam,
		steam_id = 76561198000000001,
		port     = 27015,
	}
	m.mode = .Comp
	m.players = 3
	m.max_players = 4
	m.phase = 2
	m.joinable = true
	m.draining = false

	buf: [MM_MAX_DATAGRAM]u8
	w := writer(buf[:])
	frame_begin(&w, .Server_Heartbeat)
	write_server_heartbeat(&w, m)
	testing.expect(t, !w.overflow)

	r, msg, ok := frame_open(buf[:w.off])
	testing.expect(t, ok)
	testing.expect_value(t, msg, Mm_Msg.Server_Heartbeat)
	back, rok := read_server_heartbeat(&r)
	testing.expect(t, rok)
	testing.expect(t, back == m)

	// truncated datagram flags, not crashes
	r2, _, _ := frame_open(buf[:w.off - 5])
	_, rok2 := read_server_heartbeat(&r2)
	testing.expect(t, !rok2)
}

@(test)
test_udp_addr_roundtrip :: proc(t: ^testing.T) {
	a := Server_Addr {
		kind = .Udp,
		ip4  = {192, 168, 1, 7},
		port = 27100,
	}
	buf: [32]u8
	w := writer(buf[:])
	write_server_addr(&w, a)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	testing.expect(t, read_server_addr(&r) == a)
	testing.expect(t, !r.error)
}

@(test)
test_bye_drain_stop_roundtrip :: proc(t: ^testing.T) {
	token := token_from_string("t")
	id := u64(7777)

	buf: [MM_MAX_DATAGRAM]u8
	w := writer(buf[:])
	write_server_bye(&w, {token, id})
	write_server_drain(&w, {token, id})
	write_stop_server(&w, {token, id})
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	bye, ok1 := read_server_bye(&r)
	drain, ok2 := read_server_drain(&r)
	stop, ok3 := read_stop_server(&r)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect(t, bye == Server_Bye{token, id})
	testing.expect(t, drain == Server_Drain{token, id})
	testing.expect(t, stop == Stop_Server{token, id})
}

@(test)
test_agent_spawn_roundtrip :: proc(t: ^testing.T) {
	hb := Agent_Heartbeat {
		token    = token_from_string("secret"),
		agent_id = 0xA6E27,
		region   = region_from_string("us-east"),
		capacity = 8,
		running  = 3,
	}
	spawn := Spawn_Server{hb.token, 12345, .Comp, 10}
	result := Spawn_Result{hb.token, 12345, true, 27101}

	buf: [MM_MAX_DATAGRAM]u8
	w := writer(buf[:])
	write_agent_heartbeat(&w, hb)
	write_spawn_server(&w, spawn)
	write_spawn_result(&w, result)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	hb2, ok1 := read_agent_heartbeat(&r)
	spawn2, ok2 := read_spawn_server(&r)
	result2, ok3 := read_spawn_result(&r)
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect(t, hb2 == hb)
	testing.expect(t, spawn2 == spawn)
	testing.expect(t, result2 == result)
}

@(test)
test_find_roundtrip :: proc(t: ^testing.T) {
	q := Find_Server {
		nonce        = 0xC0FFEE,
		region       = region_from_string("eu"),
		game_version = 9,
		accepts      = ACCEPT_STEAM,
		mode         = .TDM,
	}
	a := Find_Response {
		nonce = q.nonce,
		status = .Ok,
		addr = {kind = .Steam, steam_id = 90071996842377216},
	}

	buf: [MM_MAX_DATAGRAM]u8
	w := writer(buf[:])
	write_find_server(&w, q)
	write_find_response(&w, a)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	q2, ok1 := read_find_server(&r)
	a2, ok2 := read_find_response(&r)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, q2 == q)
	testing.expect(t, a2 == a)
}

@(test)
test_region_helpers :: proc(t: ^testing.T) {
	// zero-padding past len is what makes == comparison valid
	a := region_from_string("eu")
	b := region_from_string("eu")
	c := region_from_string("us")
	testing.expect(t, a == b)
	testing.expect(t, a != c)
	testing.expect_value(t, region_string(&a), "eu")

	// oversized region truncates to the block, consistently on both ends
	long := region_from_string("a-very-long-region-name")
	testing.expect_value(t, long.len, u8(MM_MAX_REGION))
}

@(test)
test_queue_roundtrip :: proc(t: ^testing.T) {
	enter := Queue_Enter {
		nonce        = 0xBADC0DE,
		region       = region_from_string("eu"),
		game_version = 10,
		accepts      = ACCEPT_UDP | ACCEPT_STEAM,
		mode         = .Comp,
	}
	leave := Queue_Leave {
		nonce = enter.nonce,
	}
	reply := Queue_Reply {
		nonce  = enter.nonce,
		status = .Queued,
		queued = 2,
		needed = 5,
	}
	assign := Match_Assign {
		nonce    = enter.nonce,
		match_id = 0xFEED_F00D_0000_0001,
		addr     = {kind = .Udp, ip4 = {10, 0, 0, 2}, port = 27101},
	}

	buf: [MM_MAX_DATAGRAM]u8
	w := writer(buf[:])
	write_queue_enter(&w, enter)
	write_queue_leave(&w, leave)
	write_queue_reply(&w, reply)
	write_match_assign(&w, assign)
	testing.expect(t, !w.overflow)

	r := reader(buf[:w.off])
	enter2, ok1 := read_queue_enter(&r)
	leave2, ok2 := read_queue_leave(&r)
	reply2, ok3 := read_queue_reply(&r)
	assign2, ok4 := read_match_assign(&r)
	testing.expect(t, ok1 && ok2 && ok3 && ok4)
	testing.expect(t, enter2 == enter)
	testing.expect(t, leave2 == leave)
	testing.expect(t, reply2 == reply)
	testing.expect(t, assign2 == assign)

	// truncated flags, not crashes
	r2 := reader(buf[:3])
	_, rok := read_queue_enter(&r2)
	testing.expect(t, !rok)
}

@(test)
test_queue_datagram_sizes :: proc(t: ^testing.T) {
	// each queue message must fit a control datagram alone, frame included
	buf: [MM_MAX_DATAGRAM]u8

	w := writer(buf[:])
	frame_begin(&w, .Queue_Enter)
	write_queue_enter(&w, {region = region_from_string("a-very-long-regio")})
	testing.expect(t, !w.overflow)
	testing.expect(t, w.off < MM_MAX_DATAGRAM / 4)

	w = writer(buf[:])
	frame_begin(&w, .Match_Assign)
	write_match_assign(&w, {addr = {kind = .Steam, steam_id = max(u64)}})
	testing.expect(t, !w.overflow)
	testing.expect(t, w.off < MM_MAX_DATAGRAM / 4)
}
