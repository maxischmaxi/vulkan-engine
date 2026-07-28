package protocol

// One endpoint's view of a two-way packet stream: sequencing, acknowledgement,
// and a reliable-ordered control channel in the Quake 3 style. Both the client
// and every server-side client slot hold one of these.
//
// Reliability works by redundant piggyback, not by resend timers: every
// outgoing packet carries the entire window of unacknowledged reliable
// messages again. Control traffic is tiny (a join, a phase change, a kill), so
// the redundancy costs a few dozen bytes, and a reliable message survives any
// loss the moment one packet gets through. `reliable_ack` in the header is the
// next reliable sequence the sender expects, i.e. everything below it has been
// delivered and processed in order.

// Packet header, on every datagram:
//   magic u16, version u8, flags u8, session u32,
//   sequence u16, ack u16, ack_bits u32, reliable_ack u16
HEADER_SIZE :: 18

FLAG_HAS_RELIABLE :: u8(1 << 0)

// 64 outstanding control messages is far beyond anything the game produces;
// hitting the cap means the peer is gone, and the caller should treat it as a
// disconnect.
RELIABLE_WINDOW :: 64
MAX_RELIABLE_PAYLOAD :: 64

// The most reliable messages one incoming packet can hand back. The sender
// never has more in flight than its window, and in practice it is one or two.
MAX_INCOMING_RELIABLE :: RELIABLE_WINDOW

Reliable_Slot :: struct {
	msg_id:  Msg_Id,
	size:    u8,
	payload: [MAX_RELIABLE_PAYLOAD]u8,
}

Connection :: struct {
	session:        u32,
	// packet level
	local_seq:      u16, // next outgoing packet sequence
	remote_seq:     u16, // highest packet sequence received
	ack_bits:       u32, // bit n = packet remote_seq-1-n received
	started:        bool, // false until the first packet arrives (remote_seq is not yet meaningful)
	// reliable send side: unacked window is [rel_acked, rel_next)
	rel_slots:      [RELIABLE_WINDOW]Reliable_Slot,
	rel_next:       u16,
	rel_acked:      u16,
	// reliable receive side
	rel_expected:   u16,
	// filled by connection_read for the caller to drain, in order
	incoming:       [MAX_INCOMING_RELIABLE]Reliable_Slot,
	incoming_count: int,
}

connection_init :: proc(c: ^Connection, session: u32) {
	c^ = {}
	c.session = session
}

// Wrap-aware "a is newer than b" over u16 sequence numbers.
seq_greater :: proc(a, b: u16) -> bool {
	return a != b && a - b < 0x8000
}

// Queues a control message for reliable, ordered delivery. False means the
// window is full -- the peer has not acknowledged anything for a long time and
// should be dropped.
queue_reliable :: proc(c: ^Connection, id: Msg_Id, payload: []u8) -> bool {
	if len(payload) > MAX_RELIABLE_PAYLOAD do return false
	if c.rel_next - c.rel_acked >= RELIABLE_WINDOW do return false

	slot := &c.rel_slots[c.rel_next % RELIABLE_WINDOW]
	slot.msg_id = id
	slot.size = u8(len(payload))
	copy(slot.payload[:], payload)
	c.rel_next += 1
	return true
}

// Convenience: serialize a message with its writer proc straight into the
// reliable queue.
queue_reliable_msg :: proc(
	c: ^Connection,
	id: Msg_Id,
	write: proc(w: ^Writer, m: $T),
	m: T,
) -> bool {
	buf: [MAX_RELIABLE_PAYLOAD]u8
	w := writer(buf[:])
	write(&w, m)
	if w.overflow do return false
	return queue_reliable(c, id, buf[:w.off])
}

// Starts an outgoing packet: header plus the whole unacked reliable window.
// The caller appends unreliable messages after this and sends w.buf[:w.off].
connection_begin_packet :: proc(c: ^Connection, w: ^Writer) {
	pending := c.rel_next - c.rel_acked

	flags: u8 = 0
	if pending > 0 do flags |= FLAG_HAS_RELIABLE

	write_u16(w, PROTOCOL_MAGIC)
	write_u8(w, PROTOCOL_VERSION)
	write_u8(w, flags)
	write_u32(w, c.session)
	write_u16(w, c.local_seq)
	write_u16(w, c.remote_seq)
	write_u32(w, c.ack_bits)
	write_u16(w, c.rel_expected)
	c.local_seq += 1

	if pending > 0 {
		write_u16(w, c.rel_acked)
		write_u8(w, u8(pending))
		for i in 0 ..< pending {
			slot := &c.rel_slots[(c.rel_acked + i) % RELIABLE_WINDOW]
			write_u8(w, u8(slot.msg_id))
			write_u8(w, slot.size)
			write_bytes(w, slot.payload[:slot.size])
		}
	}
}

// Parses a datagram's header and reliable block. On success the returned
// Reader sits at the first unreliable message; freshly deliverable reliable
// messages are in c.incoming[:c.incoming_count], in order, exactly once.
//
// Packets older than the newest seen are dropped whole: inputs are redundant,
// snapshots are superseded, and the reliable window rides on every packet, so
// a stale datagram carries nothing the connection still needs.
connection_read :: proc(c: ^Connection, data: []u8) -> (r: Reader, ok: bool) {
	c.incoming_count = 0

	r = reader(data)
	magic := read_u16(&r)
	version := read_u8(&r)
	flags := read_u8(&r)
	session := read_u32(&r)
	sequence := read_u16(&r)
	ack := read_u16(&r)
	ack_bits := read_u32(&r)
	reliable_ack := read_u16(&r)
	if r.error do return r, false
	if magic != PROTOCOL_MAGIC || version != PROTOCOL_VERSION do return r, false
	if session != c.session do return r, false

	if c.started {
		if !seq_greater(sequence, c.remote_seq) do return r, false
		shift := sequence - c.remote_seq
		c.ack_bits = shift >= 32 ? 0 : (c.ack_bits << shift) | (1 << (shift - 1))
	} else {
		c.started = true
	}
	c.remote_seq = sequence
	_ = ack
	_ = ack_bits // kept for RTT/loss stats and future delta baselines

	// Everything below the peer's reliable_ack is delivered; free those slots.
	if seq_greater(reliable_ack, c.rel_acked) {
		advanced := reliable_ack - c.rel_acked
		if advanced <= c.rel_next - c.rel_acked {
			c.rel_acked = reliable_ack
		}
	}

	if flags & FLAG_HAS_RELIABLE != 0 {
		rel_seq := read_u16(&r)
		count := read_u16_from_u8(&r)
		for i in 0 ..< count {
			id := Msg_Id(read_u8(&r))
			size := read_u8(&r)
			if int(size) > MAX_RELIABLE_PAYLOAD {
				r.error = true
			}
			if r.error do return r, false

			slot: Reliable_Slot
			slot.msg_id = id
			slot.size = size
			read_bytes(&r, slot.payload[:size])
			if r.error do return r, false

			// In-order delivery: exactly the next expected sequence passes;
			// duplicates fall through. A gap cannot occur, because the sender
			// always transmits its window contiguously from rel_acked.
			if rel_seq + i == c.rel_expected {
				if c.incoming_count < MAX_INCOMING_RELIABLE {
					c.incoming[c.incoming_count] = slot
					c.incoming_count += 1
				}
				c.rel_expected += 1
			}
		}
	}

	return r, !r.error
}

@(private = "file")
read_u16_from_u8 :: proc(r: ^Reader) -> u16 {
	return u16(read_u8(r))
}
