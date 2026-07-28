package game

import "core:math"

// The one place yaw and pitch turn into direction vectors. The client's camera
// delegates here and the simulation reads it directly, so the basis the
// renderer draws with and the basis the movement steers by can never drift --
// which is what makes client prediction land on the server's numbers.
//
// yaw = 0 looks east (+X), yaw = 90 looks north (+Y). Degrees.

yaw_forward_flat :: proc(yaw: f32) -> [3]f32 {
	r := math.to_radians(yaw)
	return {math.cos(r), math.sin(r), 0}
}

yaw_right :: proc(yaw: f32) -> [3]f32 {
	r := math.to_radians(yaw)
	return {math.sin(r), -math.cos(r), 0}
}

view_forward :: proc(yaw, pitch: f32) -> [3]f32 {
	ry := math.to_radians(yaw)
	rp := math.to_radians(pitch)
	cp := math.cos(rp)
	return {cp * math.cos(ry), cp * math.sin(ry), math.sin(rp)}
}
