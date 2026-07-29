// Where a datagram came from and how to answer it. The wire protocol does not
// care: a peer is either a raw UDP endpoint (the insecure dev transport) or a
// Steam networking connection whose SteamID arrived cryptographically
// authenticated. Slots store one and every send dispatches on it.
package main

import steam "../../steamworks"
import "core:fmt"
import "core:net"

Peer_Kind :: enum u8 {
	Udp,
	Steam,
}

Peer :: struct {
	kind:     Peer_Kind,
	ep:       net.Endpoint, // .Udp
	conn:     steam.HSteamNetConnection, // .Steam
	// .Steam only: the identity Steam verified before the connection opened.
	// Trustworthy in a way nothing inside the datagram is.
	steam_id: u64,
}

peer_equal :: proc(a, b: Peer) -> bool {
	if a.kind != b.kind do return false
	switch a.kind {
	case .Udp:
		return a.ep == b.ep
	case .Steam:
		return a.conn == b.conn
	}
	return false
}

// For logs only. Temp-allocated, freed with the tick.
peer_desc :: proc(peer: Peer) -> string {
	switch peer.kind {
	case .Udp:
		return net.endpoint_to_string(peer.ep, context.temp_allocator)
	case .Steam:
		return fmt.tprintf("steam:{}", peer.steam_id)
	}
	return "?"
}
