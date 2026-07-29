package main

import ac_core "../anticheat"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"

// The ban store. "Global ban list" is this file today and a backend later;
// ban_add is the one write seam a sync would replace, ban_list_load the one
// read seam. Loaded once at startup, appended on every ban, looked up only on
// the handshake path -- the tick loop never touches it.

BAN_FILE_DEFAULT :: "bans.txt"

Ban_List :: struct {
	// Both the banned account and its family-sharing owner key the same entry,
	// so one lookup answers every connect-time question.
	ids:  map[u64]ac_core.Ban_Line,
	ips:  map[u32]bool, // dev/UDP transport only; SDR never reveals an IP
	path: string,
}

bans: Ban_List

ban_list_load :: proc(path: string) {
	bans.path = path
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		// No file yet is the common case: an empty list.
		return
	}
	defer delete(data)

	text := string(data)
	loaded := 0
	for line in strings.split_lines_iterator(&text) {
		entry, ok := ac_core.parse_ban_line(line)
		if !ok do continue // comments, blanks, torn appends
		ban_remember(entry)
		loaded += 1
	}
	log.infof("Server: ban list {} holds {} entries", path, loaded)
}

// Memory plus append, the only write API. A crash mid-append tears at most the
// last line, which the loader then skips -- and appending, unlike rewriting,
// preserves whatever comments the operator keeps in the file.
ban_add :: proc(entry: ac_core.Ban_Line) {
	ban_remember(entry)

	buf: [128]u8
	line, ok := ac_core.format_ban_line(entry, buf[:])
	if !ok {
		log.error("Server: ban entry did not format, not persisted")
		return
	}
	f, err := os.open(bans.path, {.Write, .Create, .Append})
	if err != nil {
		log.errorf("Server: cannot open ban list {}: {}", bans.path, err)
		return
	}
	defer os.close(f)
	os.write_string(f, line)
	os.write_string(f, "\n")
}

@(private = "file")
ban_remember :: proc(entry: ac_core.Ban_Line) {
	if entry.steam_id != 0 do bans.ids[entry.steam_id] = entry
	if entry.owner_id != 0 do bans.ids[entry.owner_id] = entry
	if entry.ip != 0 do bans.ips[entry.ip] = true
}

// Id 0 marks an insecure/UDP peer and must never match an entry.
ban_has_steam :: proc(steam_id: u64) -> bool {
	if steam_id == 0 do return false
	return steam_id in bans.ids
}

ban_has_ip :: proc(ep: net.Endpoint) -> bool {
	ip := ban_ip_key(ep)
	if ip == 0 do return false
	return ip in bans.ips
}

// IPv4 only: the dev transport binds IP4. Anything else keys 0 = unbannable.
ban_ip_key :: proc(ep: net.Endpoint) -> u32 {
	addr, ok := ep.address.(net.IP4_Address)
	if !ok do return 0
	return u32(addr[0]) << 24 | u32(addr[1]) << 16 | u32(addr[2]) << 8 | u32(addr[3])
}
