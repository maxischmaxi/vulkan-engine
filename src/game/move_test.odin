package game

import "../physics"
import "core:testing"

// Descending stairs through the full pawn move: the step-down snap must keep
// the pawn grounded on every tread, fire no landing events, and report the
// whole descent through Move_Events so the eye smoothing sees it.

@(private = "file")
close :: proc(a, b: f32) -> bool {
	return abs(a - b) < 0.001
}

@(private = "file")
stairs_state :: proc() -> (gs: Game_State, brushes: []Brush) {
	b: [dynamic]Brush
	add_floor(&b, -4, -3, 0, 3, 1.5) // top platform
	add_ramp(&b, 0, -3, 2.5, 3, 1.5, GROUND_Z, along_y = false) // 0.5 m treads
	add_floor(&b, 2.5, -3, 20, 3, GROUND_Z) // bottom floor
	brushes = b[:]
	gs.collision = bake_collision(brushes)
	gs.grid = physics.grid_build(gs.collision)
	return
}

@(test)
test_pawn_descends_stairs_grounded :: proc(t: ^testing.T) {
	gs, brushes := stairs_state()
	defer {
		physics.grid_destroy(&gs.grid)
		delete(gs.collision)
		delete(brushes)
	}

	p: Pawn
	init_pawn(&p, {-2, 0, 1.5}, 0) // yaw 0 walks +x, down the stairs
	input := Pawn_Input {
		buttons = {.Forward},
	}

	// settle onto the platform before measuring
	for _ in 0 ..< 5 {
		pawn_move(&gs, &p, {}, TICK_DT)
	}
	testing.expect(t, p.body.on_ground)

	start_z := p.body.position.z
	stepped_total: f32
	for _ in 0 ..< 96 {
		ev := pawn_move(&gs, &p, input, TICK_DT)
		stepped_total += ev.stepped
		testing.expectf(t, !ev.landed, "landing fired at x = {}", p.body.position.x)
		testing.expectf(t, p.body.on_ground, "went airborne at x = {}", p.body.position.x)
	}

	testing.expectf(
		t,
		p.body.position.x > 4,
		"did not clear the stairs, x = {}",
		p.body.position.x,
	)
	testing.expectf(
		t,
		close(p.body.position.z, FLOOR_SLAB),
		"not on the bottom floor, z = {}",
		p.body.position.z,
	)
	testing.expectf(
		t,
		close(stepped_total, p.body.position.z - start_z),
		"eye smoothing missed part of the descent: reported {}, moved {}",
		stepped_total,
		p.body.position.z - start_z,
	)
}
