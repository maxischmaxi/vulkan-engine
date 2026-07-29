// The insecure transport: raw UDP, no identity, no encryption. This is what
// local development runs on and what -insecure keeps as the only transport.
// STEAM_REQUIRED builds compile the bodies to stubs and never bind the port,
// so a release server is simply not reachable this way.
package main

import "../protocol"
import "core:log"
import "core:net"

recv_buf: [protocol.MTU]u8

udp_open :: proc(port: int) -> bool {
	when STEAM_REQUIRED {
		log.info("Server: UDP transport compiled out, Steam only")
		return false
	} else {
		socket, err := net.make_bound_udp_socket(net.IP4_Any, port)
		if err != nil {
			log.errorf("Cannot bind UDP port {}: {}", port, err)
			return false
		}
		sv.socket = socket
		if block_err := net.set_blocking(sv.socket, false); block_err != nil {
			log.errorf("Cannot make the socket non-blocking: {}", block_err)
			net.close(sv.socket)
			return false
		}
		log.infof("Server: listening on UDP {}", port)
		return true
	}
}

udp_close :: proc() {
	when !STEAM_REQUIRED {
		net.close(sv.socket)
	}
}

receive_packets :: proc() {
	when !STEAM_REQUIRED {
		for {
			n, ep, err := net.recv_udp(sv.socket, recv_buf[:])
			if err == .Would_Block do break
			if err != nil {
				// Transient network errors are logged and survived; a dead socket
				// would spin here, so anything persistent shows up loudly.
				log.warnf("Server: recv error {}", err)
				break
			}
			if n < protocol.HEADER_SIZE do continue
			handle_packet(Peer{kind = .Udp, ep = ep}, recv_buf[:n])
		}
	}
}

udp_send_to :: proc(ep: net.Endpoint, data: []u8) {
	when !STEAM_REQUIRED {
		if _, err := net.send_udp(sv.socket, data, ep); err != nil {
			log.warnf("Server: send error {}", err)
		}
	}
}
