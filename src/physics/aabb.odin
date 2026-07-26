package physics

// Axis-aligned bounding box in world space, metres. The whole map is built from
// these, so they serve as render geometry, collision volumes and raycast targets
// at once.
Aabb :: struct {
	min, max: [3]f32,
}

// Strict inequality: resting exactly on a surface must not count as penetrating
// it, otherwise standing still would trigger a push-out every frame.
overlaps :: proc(a, b: Aabb) -> bool {
	return(
		a.min.x < b.max.x &&
		a.max.x > b.min.x &&
		a.min.y < b.max.y &&
		a.max.y > b.min.y &&
		a.min.z < b.max.z &&
		a.max.z > b.min.z \
	)
}

contains :: proc(b: Aabb, p: [3]f32) -> bool {
	return(
		p.x >= b.min.x &&
		p.x <= b.max.x &&
		p.y >= b.min.y &&
		p.y <= b.max.y &&
		p.z >= b.min.z &&
		p.z <= b.max.z \
	)
}

expand :: proc(b: Aabb, by: f32) -> Aabb {
	return {min = b.min - by, max = b.max + by}
}

center :: proc(b: Aabb) -> [3]f32 {
	return (b.min + b.max) * 0.5
}

overlaps_any :: proc(a: Aabb, boxes: []Aabb) -> bool {
	for b in boxes {
		if overlaps(a, b) do return true
	}
	return false
}
