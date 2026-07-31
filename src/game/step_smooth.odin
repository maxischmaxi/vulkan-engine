package game

// Client-side smoothing for the rendered feet z. Pure math with no state of
// its own -- the caller keeps last frame's smoothed and raw values. It lives
// in the game package to be testable; the server never calls it.
//
// The simulation moves the body in hard vertical jumps: step_move climbs a
// whole stair inside one tick and snap_to_ground drops one the same way. The
// render interpolation already spreads each jump across its tick, so the view
// must not book the same jump again from move events -- that counted the step
// twice and shook the camera on every tread. Instead the camera smooths what
// is actually rendered: grounded, the eye trails the interpolated feet at a
// constant rate and never owes more than max_lag; airborne, raw motion passes
// through 1:1 so jumps and falls stay crisp while any owed offset bleeds off.
smooth_feet_z :: proc(
	smooth_prev, raw_prev, raw_now: f32,
	on_ground: bool,
	rate, max_lag, dt: f32,
) -> f32 {
	// Grounded absorbs this frame's raw motion into the offset (stairs,
	// snap-downs, reconcile corrections); airborne measures against last
	// frame's raw z, so this frame's ballistic motion is untouched.
	base := on_ground ? raw_now : raw_prev
	offset := clamp(smooth_prev - base, -max_lag, max_lag)

	if dt > 0 {
		step := rate * dt
		if offset > 0 {
			offset = max(offset - step, 0)
		} else {
			offset = min(offset + step, 0)
		}
	}
	return raw_now + offset
}
