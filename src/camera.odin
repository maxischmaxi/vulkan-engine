package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "game"

// Yaw turns around world Z, pitch around the camera's own right axis.
// yaw = 0 looks east (+X), yaw = 90 looks north (+Y).
Camera :: struct {
	position:       [3]f32,
	yaw, pitch:     f32, // degrees
	fov_horizontal: f32,
	near, far:      f32,
	sensitivity:    f32, // multiplier on top of the counter-strike constant
}

camera: Camera

// Counter-strike turns 0.022 degrees per mouse count; keeping that constant
// means a sensitivity value here means the same thing it does in-game.
CS_DEGREES_PER_COUNT :: 0.022

// The unscoped lens; scoped weapons narrow fov_horizontal from here and turn
// slower with it, so a flick covers the same screen distance either way.
DEFAULT_FOV :: f32(90)

// Looking straight up or down would make the view matrix degenerate, since
// forward would be parallel to the world up axis.
MAX_PITCH :: 89.0

init_camera :: proc() {
	camera = Camera {
		position       = game.SPAWN_POSITION + {0, 0, game.EYE_HEIGHT},
		yaw            = game.SPAWN_YAW,
		pitch          = 0,
		fov_horizontal = DEFAULT_FOV,
		near           = 0.05,
		far            = 250,
		sensitivity    = 2.0,
	}
	log_camera_fov()
}

camera_apply_mouse :: proc(dx, dy: f32) {
	scale := camera.sensitivity * CS_DEGREES_PER_COUNT * (camera.fov_horizontal / DEFAULT_FOV)
	camera.yaw -= dx * scale
	camera.pitch -= dy * scale
	camera.pitch = clamp(camera.pitch, -MAX_PITCH, MAX_PITCH)

	// Keep yaw bounded so it cannot lose float precision over a long session.
	// math.mod alone leaves the range at (-360, 360), which is bounded but not
	// canonical: the same heading would compare unequal depending on which way
	// you turned to reach it.
	camera.yaw = math.mod(camera.yaw, 360)
	if camera.yaw >= 180 {
		camera.yaw -= 360
	} else if camera.yaw < -180 {
		camera.yaw += 360
	}
}

// All three delegate to the game package's basis math: the simulation steers
// by the same formulas, and prediction only works if the two can never drift.
//
// forward and right run through the viewpunch: they feed only the rendered
// view (view matrix, viewmodel, shadows, light culling). Everything that goes
// near the wire reads camera.yaw/camera.pitch directly and must stay raw.
camera_forward :: proc() -> [3]f32 {
	yaw, pitch := punched_view_angles()
	return game.view_forward(yaw, pitch)
}

// Horizontal only: walking must not drive you into the floor when looking down.
camera_forward_flat :: proc() -> [3]f32 {
	return game.yaw_forward_flat(camera.yaw)
}

camera_right :: proc() -> [3]f32 {
	yaw, _ := punched_view_angles()
	return game.yaw_right(yaw)
}

camera_view :: proc() -> linalg.Matrix4f32 {
	return linalg.matrix4_look_at_f32(
		camera.position,
		camera.position + camera_forward(),
		{0, 0, 1},
	)
}

camera_aspect :: proc() -> f32 {
	// A minimised window reports a zero extent, and one divide by zero here
	// would put a NaN in the view-projection, the cascade matrices and every
	// vertex that touches them.
	if g.swapchain_extent.width == 0 || g.swapchain_extent.height == 0 {
		return REFERENCE_ASPECT
	}
	return f32(g.swapchain_extent.width) / f32(g.swapchain_extent.height)
}

// Shooters quote fov horizontally, but only ever at 4:3. Everything wider keeps
// the vertical angle and gains horizontally -- hor+, what counter-strike does.
REFERENCE_ASPECT :: f32(4.0) / 3.0

// Pinning the horizontal angle instead, which is what this used to do, inverts
// the relationship: the narrower the window the wider the vertical angle, until
// a tall window is a fisheye. Hor+ never distorts, it only shows more or less
// to the sides.
//
// Past this much horizontal angle even hor+ starts to bend at the edges, and a
// window dragged wide enough becomes a sight advantage. Beyond it the vertical
// angle gives way instead.
MAX_HORIZONTAL_FOV :: f32(120)

// Tangents of the half angles of the view frustum. The one place that decides
// how wide the view is: the projection, the viewmodel and the shadow cascades
// all read it, so they cannot disagree.
camera_half_tangents :: proc(fov_horizontal: f32) -> (half_w, half_h: f32) {
	aspect := camera_aspect()

	half_h = math.tan(math.to_radians(fov_horizontal) * 0.5) / REFERENCE_ASPECT
	half_w = half_h * aspect

	limit := math.tan(math.to_radians(MAX_HORIZONTAL_FOV) * 0.5)
	if half_w > limit {
		half_w = limit
		half_h = half_w / aspect
	}
	return
}

// What the player is actually shown, which is not what the projection covers:
// the scope masks the picture down to a centred square (draw_scope), so a scoped
// view is narrower than its own frustum. Anything that has to land on a
// particular pixel asks for this rather than for the frustum.
visible_half_tangents :: proc(fov_horizontal: f32, masked: bool) -> (half_w, half_h: f32) {
	half_w, half_h = camera_half_tangents(fov_horizontal)
	if masked {
		// The mask is min(width, height) on a side, so the wider axis is the one
		// that loses.
		side := min(half_w, half_h)
		half_w, half_h = side, side
	}
	return
}

camera_projection :: proc() -> linalg.Matrix4f32 {
	half_w, half_h := camera_half_tangents(camera.fov_horizontal)
	return perspective_tangents(half_w, half_h, camera.near, camera.far)
}

// Reports what the current window actually shows. Called on every swapchain
// rebuild, so dragging the window is checkable against numbers rather than
// against a feeling.
log_camera_fov :: proc() {
	half_w, half_h := camera_half_tangents(camera.fov_horizontal)
	log.infof(
		"FOV: {:.1f} deg horizontal, {:.1f} deg vertical, aspect {:.3f}",
		2 * math.to_degrees(math.atan(half_w)),
		2 * math.to_degrees(math.atan(half_h)),
		camera_aspect(),
	)
}

camera_view_projection :: proc() -> linalg.Matrix4f32 {
	return camera_projection() * camera_view()
}

// The lens the viewmodel is composed through. Counter-strike's 60 is the usual
// choice, and it was right while the weapon was blocks positioned by hand -- but
// the imported models come out of scenes framed by an 18 mm lens on a 36 mm
// sensor, which is 90 degrees, and they are posed relative to that camera rather
// than to a grip offset.
//
// Rendering them through anything narrower is a zoom: the same weapon, magnified,
// with the near arm filling the screen. Matching the lens they were built for is
// what puts them back where the artist framed them.
VIEWMODEL_FOV :: 90.0

// Its own near plane too -- the weapon sits centimetres from the eye, well
// inside the world's 5 cm near plane.
VIEWMODEL_NEAR :: 0.005
VIEWMODEL_FAR :: 10.0

viewmodel_view_projection :: proc() -> linalg.Matrix4f32 {
	half_w, half_h := camera_half_tangents(VIEWMODEL_FOV)
	proj := perspective_tangents(half_w, half_h, VIEWMODEL_NEAR, VIEWMODEL_FAR)
	return proj * camera_view()
}

// Camera basis, right-handed: forward is where you look, right is to its right,
// up completes the set. The viewmodel hangs off these.
camera_basis :: proc() -> (right, forward, up: [3]f32) {
	forward = camera_forward()
	right = camera_right()
	up = linalg.cross(right, forward)
	return
}
