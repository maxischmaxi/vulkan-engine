package game

import "core:testing"

// The scenarios the view smoothing has to survive, replayed frame by frame:
// 64 Hz ticks whose z jumps are spread over the tick by the render lerp,
// sampled at 256 Hz. Rate and lag are passed explicitly so the tests pin the
// contract, not the client's tuning constants.

@(private = "file")
RATE :: f32(3.8)
@(private = "file")
MAX_LAG :: f32(0.45)
@(private = "file")
FRAME_DT :: f32(1.0) / 256
@(private = "file")
FRAMES_PER_TICK :: 4
@(private = "file")
EPS :: f32(0.0001)

@(test)
test_smooth_descent_velocity_is_bounded :: proc(t: ^testing.T) {
	// A stair run: snap_to_ground drops 0.3 in one tick, four flat ticks
	// between treads -- the cadence of a full-speed dust2 descent.
	tick_z := f32(3.0)
	prev_tick_z := tick_z
	smooth, raw_prev := tick_z, tick_z

	for tick in 0 ..< 60 {
		prev_tick_z = tick_z
		if tick % 5 == 0 do tick_z -= 0.3

		for f in 1 ..= FRAMES_PER_TICK {
			alpha := f32(f) / FRAMES_PER_TICK
			raw := prev_tick_z + (tick_z - prev_tick_z) * alpha
			next := smooth_feet_z(smooth, raw_prev, raw, true, RATE, MAX_LAG, FRAME_DT)

			testing.expectf(
				t,
				abs(next - smooth) <= RATE * FRAME_DT + EPS,
				"eye moved {} in one frame at tick {}, limit {}",
				abs(next - smooth),
				tick,
				RATE * FRAME_DT,
			)
			testing.expectf(
				t,
				abs(next - raw) <= MAX_LAG + EPS,
				"eye owes {} at tick {}, more than one step",
				abs(next - raw),
				tick,
			)
			smooth, raw_prev = next, raw
		}
	}
}

@(test)
test_smooth_climb_converges_at_constant_rate :: proc(t: ^testing.T) {
	// One 0.45 step up, spread over its tick by the lerp, then flat ground.
	smooth, raw_prev := f32(0), f32(0)
	frames_to_arrive := 0

	for f in 1 ..= 40 {
		raw := min(f32(f) / FRAMES_PER_TICK, 1) * 0.45
		next := smooth_feet_z(smooth, raw_prev, raw, true, RATE, MAX_LAG, FRAME_DT)

		testing.expectf(t, next >= smooth - EPS, "eye moved down while climbing at frame {}", f)
		testing.expect(t, next <= raw + EPS, "eye overshot the feet")
		testing.expect(t, abs(next - smooth) <= RATE * FRAME_DT + EPS)

		smooth, raw_prev = next, raw
		if frames_to_arrive == 0 && smooth == raw do frames_to_arrive = f
	}

	testing.expectf(t, smooth == raw_prev, "eye never arrived, still {} short", raw_prev - smooth)
	testing.expectf(
		t,
		f32(frames_to_arrive) * FRAME_DT <= 0.130,
		"arrival took {} frames, more than 130 ms",
		frames_to_arrive,
	)
}

@(test)
test_smooth_airborne_motion_passes_through :: proc(t: ^testing.T) {
	// A fall with a seeded residual: the ballistic motion must render exactly
	// while the owed offset unwinds to zero and stays there.
	raw_prev := f32(2.0)
	smooth := raw_prev + 0.2

	for f in 1 ..= 40 {
		raw := raw_prev - 0.1
		next := smooth_feet_z(smooth, raw_prev, raw, false, RATE, MAX_LAG, FRAME_DT)

		expected_offset := max(smooth - raw_prev - RATE * FRAME_DT, 0)
		testing.expectf(
			t,
			abs(next - raw - expected_offset) <= EPS,
			"airborne frame {} rendered offset {}, expected {}",
			f,
			next - raw,
			expected_offset,
		)
		smooth, raw_prev = next, raw
	}
	testing.expect(t, smooth == raw_prev, "residual never fully unwound")

	// A jump-speed rise with no residual renders with zero added lag.
	for _ in 0 ..< 10 {
		raw := raw_prev + 7.5 * FRAME_DT
		smooth = smooth_feet_z(smooth, raw_prev, raw, false, RATE, MAX_LAG, FRAME_DT)
		testing.expect(t, smooth == raw, "a clean jump picked up lag")
		raw_prev = raw
	}
}

@(test)
test_smooth_teleport_clamps_to_one_step :: proc(t: ^testing.T) {
	for jump in ([2]f32{10, -10}) {
		smooth, raw_prev := f32(0), f32(0)
		raw := jump
		smooth = smooth_feet_z(smooth, raw_prev, raw, true, RATE, MAX_LAG, FRAME_DT)
		testing.expectf(
			t,
			abs(smooth - raw) <= MAX_LAG + EPS,
			"teleport by {} left the eye {} away",
			jump,
			abs(smooth - raw),
		)

		raw_prev = raw
		for _ in 0 ..< 35 { 	// > MAX_LAG / (RATE * FRAME_DT) frames
			smooth = smooth_feet_z(smooth, raw_prev, raw, true, RATE, MAX_LAG, FRAME_DT)
		}
		testing.expectf(t, smooth == raw, "eye never settled after a teleport by {}", jump)
	}
}

@(test)
test_smooth_ledge_walkoff_is_continuous :: proc(t: ^testing.T) {
	// Build up an owed offset on a grounded drop, then walk off the ledge: the
	// ground/air transition must not spend the offset in a single frame.
	smooth, raw_prev := f32(1.0), f32(1.0)
	raw := f32(0.75)
	smooth = smooth_feet_z(smooth, raw_prev, raw, true, RATE, MAX_LAG, FRAME_DT)
	raw_prev = raw
	testing.expect(t, smooth - raw > 0.2, "setup failed to owe an offset")

	fall_speed := f32(0)
	for f in 1 ..= 40 {
		fall_speed += 9.81 * FRAME_DT
		next_raw := raw_prev - fall_speed * FRAME_DT
		next := smooth_feet_z(smooth, raw_prev, next_raw, false, RATE, MAX_LAG, FRAME_DT)

		testing.expectf(
			t,
			abs(next - smooth) <= abs(next_raw - raw_prev) + RATE * FRAME_DT + EPS,
			"frame {} jumped {} -- the transition popped",
			f,
			abs(next - smooth),
		)
		smooth, raw_prev = next, next_raw
	}
}
