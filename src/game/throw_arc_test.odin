package game

import "../physics"
import "core:math/linalg"
import "core:testing"

// The preview's one obligation: it has to end where the grenade would end.
// Everything here is the same world and the same throw run twice -- once
// through the real flight, once through the prediction.

@(private = "file")
arc_world :: proc(walls: ..physics.Aabb) -> (gs: Game_State) {
	boxes := make([]physics.Aabb, 1 + len(walls))
	boxes[0] = {
		min = {-60, -60, -1},
		max = {60, 60, 0},
	}
	for w, i in walls do boxes[1 + i] = w
	gs.collision = boxes
	gs.grid = physics.grid_build(gs.collision)
	return
}

@(private = "file")
destroy_arc_world :: proc(gs: ^Game_State) {
	physics.grid_destroy(&gs.grid)
	delete(gs.collision)
}

@(test)
test_arc_starts_at_the_hand :: proc(t: ^testing.T) {
	gs := arc_world()
	defer destroy_arc_world(&gs)

	origin := [3]f32{1, 2, 1.6}
	arc := predict_throw_arc(&gs.grid, origin, throw_velocity(0, 0, .Overhand, 1, {}), 0.09)

	testing.expect(t, arc.count >= 2, "an arc needs at least a start and a step")
	testing.expect_value(t, arc.points[0], origin)
}

// A flat throw into a wall stops at the wall, and the normal points back at
// the thrower -- that normal is what the impact circle is laid on.
@(test)
test_arc_stops_at_the_first_wall :: proc(t: ^testing.T) {
	gs := arc_world(physics.Aabb{min = {8, -10, 0}, max = {8.5, 10, 6}})
	defer destroy_arc_world(&gs)

	arc := predict_throw_arc(&gs.grid, {0, 0, 1.6}, throw_velocity(0, 0, .Overhand, 1, {}), 0.09)

	testing.expect(t, arc.hit, "the wall was never found")
	testing.expectf(t, abs(arc.hit_point.x - 8) < 0.2, "stopped at x {}, wanted the wall at 8", arc.hit_point.x)
	testing.expectf(t, arc.hit_normal.x < -0.9, "normal {} does not face the thrower", arc.hit_normal)

	// Nothing beyond the wall: the line must not draw through it.
	for i in 0 ..< arc.count {
		testing.expectf(t, arc.points[i].x <= 8.05, "point {} is inside the wall", arc.points[i])
	}
}

// The promise, stated as a test: where the line ends is where the grenade
// lands. Aimed down at open floor, so the first contact IS the landing.
@(test)
test_arc_ends_where_the_grenade_lands :: proc(t: ^testing.T) {
	gs := arc_world()
	defer destroy_arc_world(&gs)

	origin := [3]f32{0, 0, 1.6}
	radius := GRENADES[.Smoke].radius

	for style in Throw_Style {
		for charge in ([?]f32{0, 0.5, 1}) {
			velocity := throw_velocity(15, -10, style, charge, {2, 0, 0})
			arc := predict_throw_arc(&gs.grid, origin, velocity, radius)
			testing.expectf(t, arc.hit, "{} at charge {} never reached the floor", style, charge)

			// The same throw, flown for real, sampled the tick it first touches
			// anything. bounce_move reports the contact; before it, the two are
			// running the identical integration.
			position := origin
			speed := velocity
			landed: [3]f32
			found := false
			for _ in 0 ..< ARC_MAX_POINTS {
				result := physics.bounce_move(
					&gs.grid,
					&position,
					&speed,
					radius,
					GRAVITY,
					GRENADES[.Smoke].restitution,
					GRENADES[.Smoke].friction,
					TICK_DT,
				)
				if result.hit_wall {
					landed = position
					found = true
					break
				}
			}
			testing.expectf(t, found, "{} at charge {} never landed for real", style, charge)

			// A tick's worth of travel: the flight reports the contact at the
			// end of the step that made it, the prediction at the point of
			// contact itself.
			gap := linalg.length(landed - arc.points[arc.count - 1])
			testing.expectf(
				t,
				gap < 0.5,
				"{} at charge {}: preview ended {} m from the landing",
				style,
				charge,
				gap,
			)
		}
	}
}

// Nothing to hit is not a failure: the line simply runs out.
@(test)
test_arc_over_the_edge_never_hits :: proc(t: ^testing.T) {
	gs := arc_world()
	defer destroy_arc_world(&gs)

	// Off the side of the floor plate and straight out.
	arc := predict_throw_arc(&gs.grid, {59, 0, 1.6}, throw_velocity(0, 20, .Overhand, 1, {}), 0.09)
	testing.expect(t, !arc.hit, "found a wall in open air")
	testing.expect(t, arc.count >= 2)
}
