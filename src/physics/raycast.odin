package physics

Ray_Hit :: struct {
	t:      f32, // distance along the ray, in metres if dir is normalised
	point:  [3]f32,
	normal: [3]f32, // outward face normal of the surface that was hit
	axis:   int, // 0/1/2 -- which slab decided the entry point
	index:  int, // index into the slice ray_scene was given
}

// A direction component below this counts as parallel to that slab. The
// alternative is dividing by it, which produces +-inf (harmless) or, when the
// origin sits exactly on the slab plane, 0/0 = NaN. NaN then loses every
// comparison silently, so the test reports whatever the comparison order
// happens to yield. In a map built entirely from axis-aligned faces, firing
// exactly along an axis is not a corner case -- it happens on any shot down a
// corridor.
PARALLEL_EPSILON :: 1e-8

// Slab method. Returns the nearest entry point in front of the origin, so a ray
// starting inside the box reports no hit: a bullet does not hit the inside of
// the wall it is already in.
//
// dir is expected to be normalised; t is then a distance in metres and max_t a
// range limit in metres.
ray_aabb :: proc(origin, dir: [3]f32, box: Aabb, max_t: f32) -> (hit: Ray_Hit, ok: bool) {
	// starting at 0 rather than -inf is what rejects hits behind the origin
	t_near: f32 = 0
	t_far := max_t
	axis := -1

	for i in 0 ..< 3 {
		if abs(dir[i]) < PARALLEL_EPSILON {
			// Never enters or leaves this slab, so the origin has to be inside
			// it already or the ray misses the box entirely.
			if origin[i] < box.min[i] || origin[i] > box.max[i] do return {}, false
			continue
		}

		inv := 1 / dir[i]
		t1 := (box.min[i] - origin[i]) * inv
		t2 := (box.max[i] - origin[i]) * inv
		if t1 > t2 do t1, t2 = t2, t1

		if t1 > t_near {
			t_near = t1
			axis = i
		}
		t_far = min(t_far, t2)

		if t_near > t_far do return {}, false
	}

	// axis still unset means no slab was entered after t=0, i.e. the origin is
	// already inside the box (or exactly on its surface facing outward).
	if axis < 0 do return {}, false

	hit.t = t_near
	hit.axis = axis
	hit.point = origin + dir * t_near
	hit.normal[axis] = dir[axis] < 0 ? 1 : -1
	return hit, true
}

// Nearest hit across a set of boxes. Each successful hit tightens the range for
// the remaining tests, so later boxes bail out early instead of computing a
// full intersection that would be discarded anyway.
ray_scene :: proc(origin, dir: [3]f32, boxes: []Aabb, max_t: f32) -> (best: Ray_Hit, ok: bool) {
	limit := max_t
	for box, i in boxes {
		h, hit := ray_aabb(origin, dir, box, limit)
		if !hit do continue

		best = h
		best.index = i
		limit = h.t
		ok = true
	}
	return
}

// Drops a ray straight down and reports where it lands. Used to place things on
// whatever surface is below a candidate position.
ground_below :: proc(point: [3]f32, boxes: []Aabb, max_drop: f32) -> (z: f32, ok: bool) {
	hit, found := ray_scene(point, {0, 0, -1}, boxes, max_drop)
	if !found do return 0, false
	return hit.point.z, true
}
