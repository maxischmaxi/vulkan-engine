package main

import "game"
import "protocol"
import "vendor:glfw"

// Which screen owns the frame. The game used to boot straight into the map;
// now every frame belongs to exactly one scene, and the update loop, the HUD
// and the crosshair all branch on it rather than on ad-hoc flags.

Scene :: enum u8 {
	Menu,
	Team_Select,
	Connecting,
	Playing,
	Practice,
	Match_End,
}

Scene_State :: struct {
	current:           Scene,
	// Playing/Practice only: the ESC overlay is up and the cursor is loose.
	// The match keeps running on the server regardless.
	paused:            bool,
	chosen_team:       game.Team,
	// The next .Connecting leads to the range rather than a match. Set by the
	// menu's PRACTICE button and --practice, cleared on the way back out.
	practice_pending:  bool,
	// A static literal, shown on the main menu after a failed connect. Not
	// owned memory: assigning a new one never frees the old.
	error_text:        string,
	// Match_End: wall clock at which the menu takes over by itself, and the
	// final score frozen at the moment the server called it.
	end_at:            f64,
	final_t, final_ct: int,
}

scene: Scene_State

// How long the end screen lingers before returning to the menu on its own.
MATCH_END_SECONDS :: 5.0

// Where the menu parks the camera: above spawn, looking gently down, so the
// map itself is the backdrop. The world keeps rendering because leaving it up
// costs nothing and looks deliberate.
MENU_CAM_HEIGHT :: f32(6)
MENU_CAM_PITCH :: f32(-15)

init_scene :: proc() {
	// The benchmark drives clock and camera directly; a menu in front of it
	// would add a click nobody is there to make.
	if bench_active() {
		scene.current = .Playing
		return
	}
	// --practice and --join skip the clicking for development and headless
	// testing. parse_cli already made the two flags mutually exclusive.
	if cli.practice {
		start_practice()
		return
	}
	if cli.join != "" {
		scene.chosen_team = cli.join == "t" ? .T : .CT
		enter_scene(.Connecting)
		return
	}
	enter_scene(.Menu)
}

// The only place a scene change happens, so cursor grabbing and per-scene
// side effects cannot scatter across the codebase.
enter_scene :: proc(next: Scene) {
	scene.current = next
	scene.paused = false

	switch next {
	case .Menu:
		grab_cursor(false)
		net_disconnect() // safe when idle; the menu never keeps a connection
		scene.practice_pending = false
		camera.position = game.SPAWN_POSITION + {0, 0, MENU_CAM_HEIGHT}
		camera.yaw = game.SPAWN_YAW
		camera.pitch = MENU_CAM_PITCH

	case .Team_Select:
		grab_cursor(false)
		scene.error_text = ""
		scene.practice_pending = false

	case .Connecting:
		grab_cursor(false)
		if scene.practice_pending {
			net_practice_start(protocol.DEFAULT_PORT)
		} else {
			net_connect_start(protocol.DEFAULT_PORT, scene.chosen_team)
		}

	case .Playing:
		reset_match()
		grab_cursor(true)

	case .Practice:
		practice_enter()

	case .Match_End:
		grab_cursor(false)
		scene.end_at = glfw.GetTime() + MATCH_END_SECONDS
	}
}

// Client-side leftovers of the previous life: the server owns the match, this
// only makes sure nothing stale is on screen when it starts.
@(private = "file")
reset_match :: proc() {
	init_player()
	init_weapons()
	buy_reset(player.loadout)
	clear_decals()

	// The startup init spawned local pawns for the benchmark; a networked
	// match renders remotes instead, so the local ones go dark.
	if !bench_active() {
		for i in 1 ..< game.MAX_PAWNS {
			gs.pawns[i].active = false
			gs.pawns[i].alive = false
		}
	}

	camera.yaw = game.SPAWN_YAW
	camera.pitch = 0
}

scene_playing :: proc() -> bool {
	return scene.current == .Playing || scene.current == .Practice
}

// Per-frame housekeeping that is not input: timers and, later, the connect
// timeout.
update_scene :: proc() {
	if scene.current == .Match_End && glfw.GetTime() >= scene.end_at {
		enter_scene(.Menu)
	}
}

// What ESC means depends on the screen. The settings UI closes itself on ESC
// and is modal, so it wins while it is open.
scene_handle_esc :: proc() {
	if !key_pressed(glfw.KEY_ESCAPE) do return
	if settings_ui.open do return
	if buy_menu.open do return // the buy menu consumes its own ESC

	switch scene.current {
	case .Menu:
	// nothing: QUIT is a button, ESC quitting a game by accident is worse

	case .Team_Select, .Match_End:
		enter_scene(.Menu)

	case .Connecting:
		net_disconnect()
		enter_scene(.Menu)

	case .Playing, .Practice:
		scene.paused = !scene.paused
		grab_cursor(!scene.paused)
	}
}
