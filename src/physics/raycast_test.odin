package physics

import "core:math"
import "core:testing"

// Unit cube from the origin, used by most of the ray tests below.
UNIT :: Aabb {
	min = {0, 0, 0},
	max = {1, 1, 1},
}

EPS :: 1e-5

close :: proc(a, b: f32) -> bool {
	return abs(a - b) < EPS
}

close3 :: proc(a, b: [3]f32) -> bool {
	return close(a.x, b.x) && close(a.y, b.y) && close(a.z, b.z)
}

// Straight at each of the six faces from outside. The normal must point back at
// the shooter, otherwise a decal placed on it would face into the wall.
@(test)
test_ray_hits_every_face :: proc(t: ^testing.T) {
	Case :: struct {
		origin, dir, want_normal: [3]f32,
		want_t:                   f32,
	}
	cases := []Case {
		{origin = {-2, 0.5, 0.5}, dir = {1, 0, 0}, want_normal = {-1, 0, 0}, want_t = 2},
		{origin = {3, 0.5, 0.5}, dir = {-1, 0, 0}, want_normal = {1, 0, 0}, want_t = 2},
		{origin = {0.5, -2, 0.5}, dir = {0, 1, 0}, want_normal = {0, -1, 0}, want_t = 2},
		{origin = {0.5, 3, 0.5}, dir = {0, -1, 0}, want_normal = {0, 1, 0}, want_t = 2},
		{origin = {0.5, 0.5, -2}, dir = {0, 0, 1}, want_normal = {0, 0, -1}, want_t = 2},
		{origin = {0.5, 0.5, 3}, dir = {0, 0, -1}, want_normal = {0, 0, 1}, want_t = 2},
	}

	for c, i in cases {
		hit, ok := ray_aabb(c.origin, c.dir, UNIT, 100)
		testing.expectf(t, ok, "case {} should hit", i)
		testing.expectf(t, close(hit.t, c.want_t), "case {}: t = {}, want {}", i, hit.t, c.want_t)
		testing.expectf(
			t,
			close3(hit.normal, c.want_normal),
			"case {}: normal = {}, want {}",
			i,
			hit.normal,
			c.want_normal,
		)
		want_point := c.origin + c.dir * c.want_t
		testing.expectf(
			t,
			close3(hit.point, want_point),
			"case {}: point = {}, want {}",
			i,
			hit.point,
			want_point,
		)
	}
}

// 45 degrees onto the -X face: the entry point must land exactly where the
// geometry says it does, not merely somewhere on the box.
@(test)
test_ray_diagonal_entry_point :: proc(t: ^testing.T) {
	inv := f32(1) / math.sqrt_f32(2)
	origin := [3]f32{-1, -1, 0.5}
	dir := [3]f32{inv, inv, 0}

	hit, ok := ray_aabb(origin, dir, UNIT, 100)
	testing.expect(t, ok)
	// travels 1 m in x and 1 m in y, so sqrt(2) along the ray
	testing.expect(t, close(hit.t, math.sqrt_f32(2)))
	testing.expect(t, close3(hit.point, {0, 0, 0.5}))
}

// Exactly along an axis. Without the parallel branch the two untouched slabs
// divide by zero, which is fine until the origin sits on a slab plane -- see
// the next test.
@(test)
test_ray_axis_aligned_hits :: proc(t: ^testing.T) {
	hit, ok := ray_aabb({-5, 0.5, 0.5}, {1, 0, 0}, UNIT, 100)
	testing.expect(t, ok)
	testing.expect(t, close(hit.t, 5))
	testing.expect(t, close3(hit.normal, {-1, 0, 0}))
}

// The origin lies exactly in the plane of two slabs and the ray runs parallel to
// both. Dividing would give 0/0 = NaN here, and NaN loses every comparison, so
// a naive slab test reports whatever its comparison order happens to produce.
@(test)
test_ray_grazes_slab_planes_without_nan :: proc(t: ^testing.T) {
	// sliding along the y=0 and z=0 planes of the box
	hit, ok := ray_aabb({-5, 0, 0}, {1, 0, 0}, UNIT, 100)
	testing.expect(t, ok, "a ray flush against two faces still enters the box")
	testing.expect(t, close(hit.t, 5))
	testing.expect(t, !math.is_nan(hit.t), "t must never be NaN")
	testing.expect(t, close3(hit.normal, {-1, 0, 0}))

	// same setup but offset off the box entirely: must miss, not NaN into a hit
	_, miss := ray_aabb({-5, -0.001, 0.5}, {1, 0, 0}, UNIT, 100)
	testing.expect(t, !miss, "parallel ray outside the slab must miss")
}

// A bullet fired from inside a wall does not hit that wall's inner surface.
@(test)
test_ray_from_inside_misses :: proc(t: ^testing.T) {
	_, ok := ray_aabb({0.5, 0.5, 0.5}, {1, 0, 0}, UNIT, 100)
	testing.expect(t, !ok)
}

@(test)
test_ray_pointing_away_misses :: proc(t: ^testing.T) {
	_, ok := ray_aabb({-2, 0.5, 0.5}, {-1, 0, 0}, UNIT, 100)
	testing.expect(t, !ok)
}

// Straight at the corner where three faces meet.
@(test)
test_ray_corner_is_deterministic :: proc(t: ^testing.T) {
	inv := f32(1) / math.sqrt_f32(3)
	hit, ok := ray_aabb({-1, -1, -1}, {inv, inv, inv}, UNIT, 100)
	testing.expect(t, ok)
	testing.expect(t, close(hit.t, math.sqrt_f32(3)))
	testing.expect(t, close3(hit.point, {0, 0, 0}))
	// all three slabs enter at the same t; the first one wins, consistently
	testing.expect_value(t, hit.axis, 0)
}

@(test)
test_ray_range_limit :: proc(t: ^testing.T) {
	// face is 2 m away
	_, just_short := ray_aabb({-2, 0.5, 0.5}, {1, 0, 0}, UNIT, 1.999)
	testing.expect(t, !just_short, "a range shorter than the distance must not hit")

	_, just_enough := ray_aabb({-2, 0.5, 0.5}, {1, 0, 0}, UNIT, 2.001)
	testing.expect(t, just_enough, "a range past the distance must hit")
}

// The nearest box wins regardless of the order they are given in -- a bot in
// front of a wall has to take the shot, not the wall behind it.
@(test)
test_ray_scene_picks_nearest :: proc(t: ^testing.T) {
	boxes := []Aabb {
		{min = {10, 0, 0}, max = {11, 1, 1}}, // far
		{min = {3, 0, 0}, max = {4, 1, 1}}, // near
		{min = {6, 0, 0}, max = {7, 1, 1}}, // middle
	}

	hit, ok := ray_scene({0, 0.5, 0.5}, {1, 0, 0}, boxes, 100)
	testing.expect(t, ok)
	testing.expect_value(t, hit.index, 1)
	testing.expect(t, close(hit.t, 3))
}

@(test)
test_ray_scene_empty_and_miss :: proc(t: ^testing.T) {
	_, ok := ray_scene({0, 0, 0}, {1, 0, 0}, {}, 100)
	testing.expect(t, !ok, "no boxes means no hit")

	boxes := []Aabb{{min = {0, 10, 0}, max = {1, 11, 1}}}
	_, ok2 := ray_scene({0, 0, 0}, {1, 0, 0}, boxes, 100)
	testing.expect(t, !ok2)
}

@(test)
test_ground_below :: proc(t: ^testing.T) {
	boxes := []Aabb {
		{min = {-10, -10, -1}, max = {10, 10, 0}}, // ground
		{min = {0, 0, 0}, max = {2, 2, 1.5}}, // platform
	}

	z, ok := ground_below({1, 1, 20}, boxes, 100)
	testing.expect(t, ok)
	testing.expect(t, close(z, 1.5), "lands on the platform, not the ground under it")

	z2, ok2 := ground_below({5, 5, 20}, boxes, 100)
	testing.expect(t, ok2)
	testing.expect(t, close(z2, 0))

	_, ok3 := ground_below({50, 50, 20}, boxes, 100)
	testing.expect(t, !ok3, "nothing below means no ground")
}
