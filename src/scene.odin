package main

import "core:strings"
import "game"
import "protocol"
import "vendor:glfw"

// Which screen owns the frame. The game used to boot straight into the map;
// now every frame belongs to exactly one scene, and the update loop, the HUD
// and the crosshair all branch on it rather than on ad-hoc flags.

Scene :: enum u8 {
	Menu,
	Mode_Select,
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
	chosen_mode:       game.Mode,
	chosen_team:       game.Team,
	// When the current wait for a match began (enter .Connecting): the queue
	// screen's elapsed clock, spanning queue and handshake alike.
	queue_started:     f64,
	// The next .Connecting leads to the range rather than a match. Set by the
	// menu's PRACTICE button and --practice, cleared on the way back out.
	practice_pending:  bool,
	// The next .Connecting enters the matchmaking queue (menu play or
	// --queue) instead of the legacy quickplay query. Needs --master.
	queue_pending:     bool,
	// The team was picked before the accept landed: the accept handler fires
	// the Join instead of the click.
	join_wish_pending: bool,
	// A static literal, shown on the main menu after a failed connect. Not
	// owned memory: assigning a new one never frees the old.
	error_text:        string,
	// Match_End: wall clock at which the menu takes over by itself, and the
	// final result frozen at the moment the server called it -- the outro may
	// read nothing else, net_disconnect wipes net_client and remote.
	end_at:            f64,
	final_t, final_ct: int,
	final_mode:        game.Mode,
	final_winner:      u8, // game.Team as u8; game.NO_WINNER = draw
}

scene: Scene_State

// How long the end screen lingers before returning to the menu on its own.
// The comp outro gets a longer beat: there is a podium to look at.
MATCH_END_SECONDS :: 5.0
MATCH_OUTRO_SECONDS :: 8.0

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
	// The HUD preview is a pure client affair: straight onto the range with no
	// server registration to depend on -- a screenshot must not need a server.
	if cli.hudpreview == "outro" {
		scene.final_mode = .Comp
		scene.final_winner = u8(game.Team.T)
		scene.final_t = 13
		scene.final_ct = 7
		enter_scene(.Match_End)
		scene.end_at = glfw.GetTime() + 3600 // hold still for the camera
		return
	}
	// The menu screens, same idea: park on the screen and hold still.
	// Connecting sets the scene directly -- enter_scene would start a connect.
	switch {
	case cli.hudpreview == "menu":
		enter_scene(.Menu)
		return
	case strings.has_prefix(cli.hudpreview, "modeselect"):
		enter_scene(.Mode_Select)
		return
	case strings.has_prefix(cli.hudpreview, "teamselect"):
		// Set directly: entering the scene would open a socket, and a
		// screenshot must not need a server.
		grab_cursor(false)
		scene.current = .Team_Select
		return
	case cli.hudpreview == "connecting":
		grab_cursor(false)
		scene.current = .Connecting
		scene.queue_started = glfw.GetTime() - 83
		return
	}
	if cli.hudpreview != "" {
		enter_scene(.Practice)
		return
	}
	// --practice and --join skip the clicking for development and headless
	// testing. parse_cli already made the two flags mutually exclusive.
	if cli.practice {
		start_practice()
		return
	}
	if cli.queue != "" {
		scene.chosen_mode = cli.queue == "comp" ? .Comp : .TDM
		scene.chosen_team = .T // a wish; the server balances
		scene.queue_pending = true
		enter_scene(.Connecting)
		return
	}
	if cli.join != "" {
		scene.chosen_team = cli.join == "t" ? .T : .CT
		// --join-delay browses the team select first; update_scene picks the
		// team once the timer runs out.
		enter_scene(cli.join_delay > 0 ? .Team_Select : .Connecting)
		return
	}
	enter_scene(.Menu)
}

// The only place a scene change happens, so cursor grabbing and per-scene
// side effects cannot scatter across the codebase.
enter_scene :: proc(next: Scene) {
	// Whoever gets here wins: a fade still waiting for its midpoint must not
	// overwrite this scene a moment from now.
	ui_transition_claim()
	scene.current = next
	scene.paused = false
	audio_stop_effects()
	audio_scene_music(next)

	switch next {
	case .Menu:
		grab_cursor(false)
		net_disconnect() // safe when idle; the menu never keeps a connection
		master_query_stop() // same: a pending server search dies with the scene
		queue_stop() // leaving the scene is leaving the queue
		queue_launch_disarm()
		scene.practice_pending = false
		scene.queue_pending = false
		camera.position = game.SPAWN_POSITION + {0, 0, MENU_CAM_HEIGHT}
		camera.yaw = game.SPAWN_YAW
		camera.pitch = MENU_CAM_PITCH

	case .Mode_Select:
		grab_cursor(false)
		// The way back out of the team select: whatever it connected to goes
		// with it. All four are safe when nothing is running.
		net_disconnect()
		master_query_stop()
		queue_stop()
		queue_launch_disarm()
		scene.join_wish_pending = false
		scene.error_text = ""
		scene.practice_pending = false

	case .Team_Select:
		grab_cursor(false)
		scene.error_text = ""
		scene.practice_pending = false
		scene.join_wish_pending = false
		// The pick needs a roster to pick from, so the connect starts here and
		// the Join waits for the click.
		team_select_connect_start()

	case .Connecting:
		grab_cursor(false)
		scene.queue_started = glfw.GetTime()
		// Coming from the team select the connection already stands (or is
		// still being resolved); this scene only waits for the phase.
		if net_client.active || master_query.active || queue_client.active {
			break
		}
		if scene.practice_pending {
			net_practice_start(protocol.DEFAULT_PORT)
		} else if cli.connect_id != 0 {
			net_connect_start_steam(cli.connect_id, scene.chosen_team)
		} else if scene.queue_pending && cli.master != "" {
			queue_start(scene.chosen_mode, scene.chosen_team)
		} else if cli.master != "" {
			master_query_start(scene.chosen_team)
		} else {
			when STEAM_REQUIRED {
				// A release server has no UDP listener, so a loopback try
				// would only burn the timeout. Until a server browser
				// exists, joining needs --connect.
				scene.error_text = "NO SERVER CONFIGURED"
				enter_scene(.Menu)
			} else {
				net_connect_start(protocol.DEFAULT_PORT, scene.chosen_team)
			}
		}

	case .Playing:
		reset_match()
		queue_launch_disarm() // the queue delivered; failures are real now
		grab_cursor(true)

	case .Practice:
		practice_enter()

	case .Match_End:
		grab_cursor(false)
		linger: f64 = scene.final_mode == .Comp ? MATCH_OUTRO_SECONDS : MATCH_END_SECONDS
		scene.end_at = glfw.GetTime() + linger
	}
}

// The team select connects but does not join: the client sits in the server's
// Connected state, receiving snapshots and the roster, until a team is picked.
// Same routing as the old start_game, minus the team.
@(private = "file")
team_select_connect_start :: proc() {
	if net_client.active || master_query.active || queue_client.active do return
	scene.queue_started = glfw.GetTime()

	if cli.connect_id != 0 {
		net_connect_start_steam(cli.connect_id, scene.chosen_team, auto_join = false)
	} else if cli.master != "" {
		// --join keeps the legacy quickplay query; menu play goes through the
		// queue, which is what start_game did.
		if cli.join != "" {
			master_query_start(scene.chosen_team, auto_join = false)
		} else {
			queue_start(scene.chosen_mode, scene.chosen_team, auto_join = false)
		}
	} else {
		when STEAM_REQUIRED {
			scene.error_text = "NO SERVER CONFIGURED"
			enter_scene(.Menu)
		} else {
			net_connect_start(protocol.DEFAULT_PORT, scene.chosen_team, auto_join = false)
		}
	}
}

// The pick itself: the Join rides the connection the team select opened, or
// waits for the accept if the handshake is still in flight.
team_select_pick :: proc(team: game.Team) {
	scene.chosen_team = team
	if net_client.got_accept {
		net_join_team(team)
		if !net_client.active do return // a failed send already sent us to the menu
	} else {
		scene.join_wish_pending = true
	}
	scene_transition_to(.Connecting)
}

// Client-side leftovers of the previous life: the server owns the match, this
// only makes sure nothing stale is on screen when it starts.
@(private = "file")
reset_match :: proc() {
	init_player()
	init_weapons()
	buy_reset(player.loadout)
	clear_decals()
	killfeed_reset()
	// A match that starts with the last one's smoke still hanging in the air
	// looks like a bug and is one.
	clear_particles()
	fx_reset_zones()

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
		scene_transition_to(.Menu)
	}
	// --join-delay: the headless stand-in for clicking a team card. The scene
	// only changes at the transition's midpoint, so the pending join is what
	// keeps this from firing every frame until then.
	if scene.current == .Team_Select &&
	   cli.join_delay > 0 &&
	   !scene.join_wish_pending &&
	   !net_client.join_pending &&
	   glfw.GetTime() - scene.queue_started > f64(cli.join_delay) {
		team_select_pick(scene.chosen_team)
	}
}

// What ESC means depends on the screen. The settings UI closes itself on ESC
// and is modal, so it wins while it is open.
scene_handle_esc :: proc() {
	if !key_pressed(glfw.KEY_ESCAPE) do return
	if settings_screen.open do return
	if buy_menu.open do return // the buy menu consumes its own ESC

	switch scene.current {
	case .Menu:
	// nothing: QUIT is a button, ESC quitting a game by accident is worse

	case .Mode_Select, .Match_End:
		scene_transition_to(.Menu)

	case .Team_Select:
		scene_transition_to(.Mode_Select) // back one step, not all the way out

	case .Connecting:
		net_disconnect()
		scene_transition_to(.Menu)

	case .Playing, .Practice:
		scene.paused = !scene.paused
		grab_cursor(!scene.paused)
	}
}
