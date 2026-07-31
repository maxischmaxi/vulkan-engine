package main

import "game"

// The audio bank: which files an event plays and how. This table is the whole
// extension point -- a new sound in the game is a row here plus one audio_emit
// at the site that knows the moment; swapping a sound is editing a filename.
// A listed file that is missing on disk logs once at startup and the event
// plays nothing, so the code never depends on any particular download.

// CWD-relative like MESH_DIR and TEXTURE_DIR: `just run` runs from the repo
// root, and that is where the curated runtime files live.
SOUND_DIR :: "sounds"

MENU_MUSIC :: "music/menu.ogg"
AMBIENT_TRACK :: "ambient/ambient_01.ogg"

Audio_Bus :: enum {
	Effects,
	Music,
	Ambient,
}

Audio_Event_Kind :: enum {
	Footstep,
	Jump,
	Land,
	Fire,
	Dry_Fire,
	Melee_Swing,
	Reload_Start,
	Reload_End,
	Weapon_Draw,
	Hit_Confirm,
	Damage_Taken,
	Kill,
	Ui_Click,
	Ui_Hover,
	Buy,
	Bomb_Planted,
	Round_Start,
	Round_End,
}

// Reserved slot for material-dependent footsteps. The collision bake strips
// materials today (game/brush.odin), so only Default exists; events already
// carry the field so adding surfaces later does not touch the emit sites.
Surface :: enum {
	Default,
}

Audio_Event :: struct {
	kind:      Audio_Event_Kind,
	pos:       [3]f32, // world, metres; ignored for local events
	weapon:    int, // index into game.WEAPONS, -1 when not weapon-specific
	intensity: f32, // 0..1; 0 means unspecified and is treated as 1
	surface:   Surface,
	local:     bool, // the own pawn: plays flat 2D at full presence
}

Audio_Spec :: struct {
	files:              []string, // relative to SOUND_DIR; random pick among loaded
	bus:                Audio_Bus,
	volume:             f32,
	pitch_jitter:       f32, // +- fraction; keeps repeats from machine-gunning
	spatial:            bool, // non-local emissions get position + attenuation
	min_distance:       f32, // metres; full volume inside
	max_distance:       f32, // metres; inaudible beyond
	cooldown:           f32, // seconds; per-kind flood guard, 0 = none
	scale_by_intensity: bool, // landing thud, damage grunt
	chrome:             bool, // interface narration; survives the scene-change cut
}

AUDIO_BANK := [Audio_Event_Kind]Audio_Spec {
	.Footstep = {
		files = {
			"footsteps/step_01.ogg",
			"footsteps/step_02.ogg",
			"footsteps/step_03.ogg",
			"footsteps/step_04.ogg",
		},
		bus = .Effects,
		volume = 0.5,
		pitch_jitter = 0.08,
		spatial = true,
		min_distance = 1.5,
		max_distance = 18,
	},
	.Jump = {
		files = {"footsteps/jump_01.ogg"},
		bus = .Effects,
		volume = 0.35,
		pitch_jitter = 0.05,
		spatial = true,
		min_distance = 1.5,
		max_distance = 12,
		cooldown = 0.1,
	},
	.Land = {
		files = {"footsteps/land_01.ogg"},
		bus = .Effects,
		volume = 0.7,
		pitch_jitter = 0.05,
		spatial = true,
		min_distance = 1.5,
		max_distance = 20,
		cooldown = 0.1,
		scale_by_intensity = true,
	},
	// Fallback when a weapon has no entry in WEAPON_FIRE_FILES.
	.Fire = {
		files = {},
		bus = .Effects,
		volume = 0.9,
		pitch_jitter = 0.03,
		spatial = true,
		min_distance = 2,
		max_distance = 60,
	},
	.Dry_Fire = {files = {"weapons/dryfire_01.ogg"}, bus = .Effects, volume = 0.4},
	.Melee_Swing = {
		files = {"weapons/knife_01.ogg", "weapons/knife_02.ogg"},
		bus = .Effects,
		volume = 0.5,
		pitch_jitter = 0.06,
		spatial = true,
		min_distance = 1.5,
		max_distance = 10,
	},
	.Reload_Start = {files = {"weapons/reload_start_01.ogg"}, bus = .Effects, volume = 0.5},
	.Reload_End = {files = {"weapons/reload_end_01.ogg"}, bus = .Effects, volume = 0.5},
	.Weapon_Draw = {files = {"weapons/draw_01.ogg"}, bus = .Effects, volume = 0.5},
	.Hit_Confirm = {files = {"ui/hit_01.ogg"}, bus = .Effects, volume = 0.45, cooldown = 0.04},
	.Damage_Taken = {
		files = {"ui/hurt_01.ogg", "ui/hurt_02.ogg", "ui/hurt_03.ogg"},
		bus = .Effects,
		volume = 0.7,
		pitch_jitter = 0.08,
		cooldown = 0.15,
		scale_by_intensity = true,
	},
	.Kill = {files = {"ui/kill_01.ogg"}, bus = .Effects, volume = 0.5, cooldown = 0.1},
	.Ui_Click = {
		files = {"ui/click_01.ogg"},
		bus = .Effects,
		volume = 0.4,
		cooldown = 0.05,
		chrome = true,
	},
	// The click file quiet and jittered stands in for a real hover tick until
	// the sound pass curates sounds/ui/hover_01.ogg.
	.Ui_Hover = {
		files = {"ui/click_01.ogg"},
		bus = .Effects,
		volume = 0.12,
		pitch_jitter = 0.06,
		cooldown = 0.06,
		chrome = true,
	},
	.Buy = {files = {"ui/buy_01.ogg"}, bus = .Effects, volume = 0.5, cooldown = 0.1},
	.Bomb_Planted = {files = {"ui/bomb_planted_01.ogg"}, bus = .Effects, volume = 0.6},
	// The round jingles are chrome: the end-of-match one is emitted on the same
	// packet that switches the scene, and the cut must not swallow it.
	.Round_Start = {
		files = {"ui/round_start_01.ogg"},
		bus = .Effects,
		volume = 0.5,
		cooldown = 0.5,
		chrome = true,
	},
	.Round_End = {
		files = {"ui/round_end_01.ogg"},
		bus = .Effects,
		volume = 0.5,
		cooldown = 0.5,
		chrome = true,
	},
}

// Per-weapon fire variants, indexed like game.WEAPONS. The knife stays empty:
// a swing is .Melee_Swing, not .Fire.
WEAPON_FIRE_FILES := [game.WEAPON_COUNT][]string {
	game.WEAPON_KNIFE  = {},
	game.WEAPON_GLOCK  = {"weapons/glock_01.ogg"},
	game.WEAPON_USP    = {"weapons/usp_01.ogg"},
	game.WEAPON_DEAGLE = {"weapons/deagle_01.ogg"},
	game.WEAPON_MAC10  = {"weapons/mac10_01.ogg"},
	game.WEAPON_MP9    = {"weapons/mp9_01.ogg"},
	game.WEAPON_NOVA   = {"weapons/nova_01.ogg"},
	game.WEAPON_AK     = {"weapons/ak_01.ogg"},
	game.WEAPON_M4     = {"weapons/m4_01.ogg"},
	game.WEAPON_AWP    = {"weapons/awp_01.ogg"},
}
