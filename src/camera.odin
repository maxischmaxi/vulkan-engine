package main

import "core:math"
import "core:math/linalg"

// Yaw turns around world Z, pitch around the camera's own right axis.
// yaw = 0 looks east (+X), yaw = 90 looks north (+Y).
Camera :: struct {
	position:    [3]f32,
	yaw, pitch:  f32, // degrees
	fov_horizontal: f32,
	near, far:   f32,
	sensitivity: f32, // multiplier on top of the counter-strike constant
}

camera: Camera

// Counter-strike turns 0.022 degrees per mouse count; keeping that constant
// means a sensitivity value here means the same thing it does in-game.
CS_DEGREES_PER_COUNT :: 0.022

// Looking straight up or down would make the view matrix degenerate, since
// forward would be parallel to the world up axis.
MAX_PITCH :: 89.0

init_camera :: proc() {
	camera = Camera {
		position       = SPAWN_POSITION + {0, 0, EYE_HEIGHT},
		yaw            = SPAWN_YAW,
		pitch          = 0,
		fov_horizontal = 90,
		near           = 0.05,
		far            = 250,
		sensitivity    = 2.0,
	}
}

camera_apply_mouse :: proc(dx, dy: f32) {
	scale := camera.sensitivity * CS_DEGREES_PER_COUNT
	camera.yaw -= dx * scale
	camera.pitch -= dy * scale
	camera.pitch = clamp(camera.pitch, -MAX_PITCH, MAX_PITCH)

	// keep yaw bounded so it cannot lose float precision over a long session
	camera.yaw = math.mod(camera.yaw, 360)
}

camera_forward :: proc() -> [3]f32 {
	yaw := math.to_radians(camera.yaw)
	pitch := math.to_radians(camera.pitch)
	cp := math.cos(pitch)
	return {cp * math.cos(yaw), cp * math.sin(yaw), math.sin(pitch)}
}

// Horizontal only: walking must not drive you into the floor when looking down.
camera_forward_flat :: proc() -> [3]f32 {
	yaw := math.to_radians(camera.yaw)
	return {math.cos(yaw), math.sin(yaw), 0}
}

camera_right :: proc() -> [3]f32 {
	yaw := math.to_radians(camera.yaw)
	return {math.sin(yaw), -math.cos(yaw), 0}
}

camera_view :: proc() -> linalg.Matrix4f32 {
	return linalg.matrix4_look_at_f32(
		camera.position,
		camera.position + camera_forward(),
		{0, 0, 1},
	)
}

camera_projection :: proc() -> linalg.Matrix4f32 {
	aspect := f32(g.swapchain_extent.width) / f32(g.swapchain_extent.height)

	// FOV is quoted horizontally in shooters, but the projection wants vertical
	half_h := math.tan(math.to_radians(camera.fov_horizontal) * 0.5)
	fov_vertical := 2 * math.atan(half_h / aspect)

	return perspective_vulkan(fov_vertical, aspect, camera.near, camera.far)
}
