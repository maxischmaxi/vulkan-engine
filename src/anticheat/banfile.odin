package anticheat

import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"

// One ban per line, hand-editable and greppable:
//
//   steam_id owner_id ip reason unix_time
//
// '#' starts a comment. A torn line (crash mid-append) fails to parse and is
// skipped by the loader, so an append-only file never poisons the parsed rest.

Ban_Line :: struct {
	steam_id: u64, // 0 = unknown (insecure/UDP peer)
	owner_id: u64, // family-sharing lender, 0 = none
	ip:       u32, // IPv4, dev/UDP transport only; 0 = unknown
	reason:   Violation,
	stamp:    i64, // unix seconds
}

parse_ban_line :: proc(line: string) -> (b: Ban_Line, ok: bool) {
	trimmed := strings.trim_space(line)
	if trimmed == "" || trimmed[0] == '#' do return

	fields: [5]string
	count := 0
	it := trimmed
	for field in strings.fields_iterator(&it) {
		if count >= len(fields) do return
		fields[count] = field
		count += 1
	}
	if count != len(fields) do return

	oks: [5]bool
	b.steam_id, oks[0] = strconv.parse_u64(fields[0])
	b.owner_id, oks[1] = strconv.parse_u64(fields[1])
	b.ip, oks[2] = parse_ip4(fields[2])
	b.reason, oks[3] = reflect.enum_from_name(Violation, fields[3])
	b.stamp, oks[4] = strconv.parse_i64(fields[4])
	for field_ok in oks {
		if !field_ok do return {}, false
	}
	return b, true
}

format_ban_line :: proc(b: Ban_Line, buf: []u8) -> (line: string, ok: bool) {
	line = fmt.bprintf(
		buf,
		"{} {} {}.{}.{}.{} {} {}",
		b.steam_id,
		b.owner_id,
		b.ip >> 24,
		(b.ip >> 16) & 0xFF,
		(b.ip >> 8) & 0xFF,
		b.ip & 0xFF,
		b.reason,
		b.stamp,
	)
	// bprintf truncates silently at capacity; an exact fit is treated as
	// truncated too, which only costs one spare byte of buffer.
	return line, len(line) < len(buf)
}

@(private = "file")
parse_ip4 :: proc(s: string) -> (ip: u32, ok: bool) {
	it := s
	parts := 0
	for part in strings.split_iterator(&it, ".") {
		n, nok := strconv.parse_u64(part)
		if !nok || n > 255 || parts >= 4 do return 0, false
		ip = ip << 8 | u32(n)
		parts += 1
	}
	if parts != 4 do return 0, false
	return ip, true
}
