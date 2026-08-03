package protocol

import "core:math"

// Manual little-endian serialization into caller-provided buffers. No
// allocation, no reflection: the wire format is the code in messages.odin, and
// these are the only primitives it is allowed to be written in.
//
// Errors are sticky flags rather than returns, so a message writes or reads
// straight through and checks once at the end. A truncated packet cannot
// panic; it comes back as `error` and gets dropped.

Writer :: struct {
	buf:      []u8,
	off:      int,
	overflow: bool,
}

Reader :: struct {
	buf:   []u8,
	off:   int,
	error: bool,
}

writer :: proc(buf: []u8) -> Writer {
	return {buf = buf}
}

reader :: proc(buf: []u8) -> Reader {
	return {buf = buf}
}

write_u8 :: proc(w: ^Writer, v: u8) {
	if w.off + 1 > len(w.buf) {
		w.overflow = true
		return
	}
	w.buf[w.off] = v
	w.off += 1
}

write_u16 :: proc(w: ^Writer, v: u16) {
	if w.off + 2 > len(w.buf) {
		w.overflow = true
		return
	}
	w.buf[w.off] = u8(v)
	w.buf[w.off + 1] = u8(v >> 8)
	w.off += 2
}

write_u32 :: proc(w: ^Writer, v: u32) {
	if w.off + 4 > len(w.buf) {
		w.overflow = true
		return
	}
	w.buf[w.off] = u8(v)
	w.buf[w.off + 1] = u8(v >> 8)
	w.buf[w.off + 2] = u8(v >> 16)
	w.buf[w.off + 3] = u8(v >> 24)
	w.off += 4
}

write_f32 :: proc(w: ^Writer, v: f32) {
	write_u32(w, transmute(u32)v)
}

write_bytes :: proc(w: ^Writer, v: []u8) {
	if w.off + len(v) > len(w.buf) {
		w.overflow = true
		return
	}
	copy(w.buf[w.off:], v)
	w.off += len(v)
}

read_u8 :: proc(r: ^Reader) -> u8 {
	if r.off + 1 > len(r.buf) {
		r.error = true
		return 0
	}
	v := r.buf[r.off]
	r.off += 1
	return v
}

read_u16 :: proc(r: ^Reader) -> u16 {
	if r.off + 2 > len(r.buf) {
		r.error = true
		return 0
	}
	v := u16(r.buf[r.off]) | u16(r.buf[r.off + 1]) << 8
	r.off += 2
	return v
}

read_u32 :: proc(r: ^Reader) -> u32 {
	if r.off + 4 > len(r.buf) {
		r.error = true
		return 0
	}
	v :=
		u32(r.buf[r.off]) |
		u32(r.buf[r.off + 1]) << 8 |
		u32(r.buf[r.off + 2]) << 16 |
		u32(r.buf[r.off + 3]) << 24
	r.off += 4
	return v
}

read_f32 :: proc(r: ^Reader) -> f32 {
	return transmute(f32)read_u32(r)
}

read_bytes :: proc(r: ^Reader, out: []u8) {
	if r.off + len(out) > len(r.buf) {
		r.error = true
		return
	}
	copy(out, r.buf[r.off:r.off + len(out)])
	r.off += len(out)
}

// ------------------------------------------------------------- quantization
//
// Angles travel quantized. The client must predict with the values the server
// will decode -- run the angle through the matching roundtrip before use, and
// the two ends compute on bit-identical floats.

// Yaw wraps to [0, 360) and lands on ~0.0055 degree steps.
quantize_yaw :: proc(yaw: f32) -> u16 {
	wrapped := math.mod(yaw, 360)
	if wrapped < 0 do wrapped += 360
	return u16(int(wrapped * (65536.0 / 360.0) + 0.5) & 0xFFFF)
}

dequantize_yaw :: proc(q: u16) -> f32 {
	return f32(q) * (360.0 / 65536.0)
}

// Pitch clamps to the camera's own +-89 and maps [-90, 90] onto the range.
quantize_pitch :: proc(pitch: f32) -> u16 {
	clamped := clamp(pitch, -89, 89)
	return u16((clamped + 90) * (65535.0 / 180.0) + 0.5)
}

dequantize_pitch :: proc(q: u16) -> f32 {
	return f32(q) * (180.0 / 65535.0) - 90
}

// Positions nothing is decided by: one centimetre over +-327 m, which is
// several times the map. Used for sound panning and for grenades in flight,
// both of which are cosmetic -- the server owns where a shot lands and where a
// grenade goes off.
//
// Player positions do NOT travel this way. They are compared bit for bit
// against the delta baseline, and a centimetre of rounding there would move
// where bullets land.
COARSE_POS_SCALE :: f32(100)

quantize_coarse_pos :: proc(v: f32) -> i16 {
	return i16(clamp(v * COARSE_POS_SCALE, -32768, 32767))
}

dequantize_coarse_pos :: proc(q: i16) -> f32 {
	return f32(q) / COARSE_POS_SCALE
}
