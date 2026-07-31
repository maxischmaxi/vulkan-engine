package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:math/rand"
import "core:strings"
import "game"
import "physics"
import ma "vendor:miniaudio"

// The audio engine: everything between an Audio_Event and the speakers.
// Game code fires audio_emit and never touches miniaudio; which file plays
// and how loud lives in audio_bank.odin. The engine is allowed to be absent
// (benchmark, headless CI, broken ALSA) -- every entry point no-ops on
// audio.ok, and with --audio-log the events still reach the log, which is
// what the headless E2E asserts against.

MAX_VOICES :: 32 // simultaneous one-shots; a ring like the tracers
MAX_VARIANTS :: 6 // file variants per event or weapon

// Metres of ground travel between two footsteps.
FOOTSTEP_STRIDE :: f32(1.9)

// Derived from the run speed rather than written as a number so a movement
// rebalance keeps the guarantee: sneak (0.52x), crouch (0.34x) and scoped
// walk (0.4x) all sit under 0.6x, so slow movement is silent without the
// audio code ever reading a key.
FOOTSTEP_MIN_SPEED :: game.WALK_SPEED * 0.6

// Below this downward speed a landing is a stair step, not a thud.
LAND_MIN_IMPACT :: f32(2.0)

// A remote pawn moving this far in one frame respawned; reset its stride.
REMOTE_TELEPORT :: f32(2.0)

// Vertical speed above which a remote pawn counts as airborne. Crude next to
// a real On_Ground scan, but ramps at walking pace stay under it.
REMOTE_AIRBORNE_VZ :: f32(3.0)

// A preloaded variant. Never played directly: emits copy it, sharing the
// decoded buffer. Only .DECODE templates may be copied -- the streamed loops
// below are played in place.
Audio_Template :: struct {
	sound: ma.sound,
	ok:    bool,
}

Audio_Voice :: struct {
	sound:  ma.sound,
	in_use: bool,
	chrome: bool, // interface narration; spared by audio_stop_effects
}

// A persistent streamed loop: the menu music and the in-game ambient bed.
// Tracks are compile-time literals, so path needs no allocation.
Audio_Loop :: struct {
	sound: ma.sound,
	ok:    bool,
	path:  string,
}

Audio_Settings :: struct {
	master, music, effects, ambient: f32, // 0..1
}

Foot_Tracker :: struct {
	travelled: f32, // metres since the last step sound
	prev:      [3]f32,
	seen:      bool,
}

Audio :: struct {
	ok:              bool, // engine came up; false makes every proc a no-op
	engine:          ma.engine,
	groups:          [Audio_Bus]ma.sound_group,
	templates:       [Audio_Event_Kind][MAX_VARIANTS]Audio_Template,
	weapon_fire:     [game.WEAPON_COUNT][MAX_VARIANTS]Audio_Template,
	voices:          [MAX_VOICES]Audio_Voice,
	next_voice:      int, // ring cursor; anything it steals has had its run
	music:           Audio_Loop,
	ambient:         Audio_Loop,
	cooldown:        [Audio_Event_Kind]f32,
	feet:            [game.MAX_PAWNS]Foot_Tracker,
	local_travelled: f32,
}

audio: Audio

audio_settings := Audio_Settings {
	master  = 0.8,
	music   = 0.5,
	effects = 1.0,
	ambient = 0.8,
}

init_audio :: proc() {
	// The benchmark measures frames, not mixing, and stays deterministic.
	if bench_active() {
		log.info("Audio: disabled for benchmark")
		return
	}

	if r := ma.engine_init(nil, &audio.engine); r != .SUCCESS {
		log.warnf("Audio: no output device ({}), running silent", r)
		return
	}

	// The game is Z-up; miniaudio assumes Y-up. Forgetting this pans sounds
	// sideways whenever the listener looks up or down.
	ma.engine_listener_set_world_up(&audio.engine, 0, 0, 0, 1)

	for bus in Audio_Bus {
		if r := ma.sound_group_init(&audio.engine, {}, nil, &audio.groups[bus]); r != .SUCCESS {
			log.warnf("Audio: sound group {} failed ({}), running silent", bus, r)
			ma.engine_uninit(&audio.engine)
			return
		}
	}

	audio.ok = true
	audio_apply_volumes()
	audio_preload()
}

destroy_audio :: proc() {
	if !audio.ok do return
	// Sounds first, engine last: a sound outliving its engine is a
	// use-after-free in the mixer thread.
	for &v in audio.voices {
		if v.in_use do ma.sound_uninit(&v.sound)
	}
	audio_loop_stop(&audio.music)
	audio_loop_stop(&audio.ambient)
	for kind in Audio_Event_Kind {
		for &t in audio.templates[kind] {
			if t.ok do ma.sound_uninit(&t.sound)
		}
	}
	for w in 0 ..< game.WEAPON_COUNT {
		for &t in audio.weapon_fire[w] {
			if t.ok do ma.sound_uninit(&t.sound)
		}
	}
	for bus in Audio_Bus {
		ma.sound_group_uninit(&audio.groups[bus])
	}
	ma.engine_uninit(&audio.engine)
	audio.ok = false
}

// The one entry point for one-shot sounds. Logging comes before the ok guard
// so headless runs without a sound device still leave the event trail the
// E2E tests grep for.
audio_emit :: proc(ev: Audio_Event) {
	if cli.audio_log {
		log.infof(
			"AUDIO: {} weapon={} intensity={:.2f} local={}",
			ev.kind,
			ev.weapon,
			ev.intensity,
			ev.local,
		)
	}
	if !audio.ok do return

	spec := &AUDIO_BANK[ev.kind]
	if spec.cooldown > 0 {
		if audio.cooldown[ev.kind] > 0 do return
		audio.cooldown[ev.kind] = spec.cooldown
	}

	variants := &audio.templates[ev.kind]
	if ev.kind == .Fire && ev.weapon >= 0 && ev.weapon < game.WEAPON_COUNT {
		variants = &audio.weapon_fire[ev.weapon]
	}

	template := pick_variant(variants)
	if template == nil do return

	voice := &audio.voices[audio.next_voice]
	audio.next_voice = (audio.next_voice + 1) % MAX_VOICES
	if voice.in_use {
		// Steal-oldest, like the tracer ring: a 33rd simultaneous sound eats
		// the oldest, which nobody hears missing.
		ma.sound_uninit(&voice.sound)
		voice.in_use = false
	}

	// A 2D sound left spatialized would sit at the world origin and fade with
	// the listener's distance from it -- the flag is not an optimization here.
	spatial := spec.spatial && !ev.local
	flags: ma.sound_flags = spatial ? {} : {.NO_SPATIALIZATION}
	if r := ma.sound_init_copy(
		&audio.engine,
		template,
		flags,
		&audio.groups[spec.bus],
		&voice.sound,
	); r != .SUCCESS {
		return
	}
	voice.in_use = true
	voice.chrome = spec.chrome

	volume := spec.volume
	if spec.scale_by_intensity && ev.intensity > 0 {
		volume *= ev.intensity
	}
	ma.sound_set_volume(&voice.sound, volume)
	if spec.pitch_jitter > 0 {
		ma.sound_set_pitch(
			&voice.sound,
			1 + rand.float32_range(-spec.pitch_jitter, spec.pitch_jitter),
		)
	}
	if spatial {
		ma.sound_set_position(&voice.sound, ev.pos.x, ev.pos.y, ev.pos.z)
		// The world is in metres; without an explicit model and range, distant
		// gunfire plays at nearly full volume.
		ma.sound_set_attenuation_model(&voice.sound, .inverse)
		ma.sound_set_min_distance(&voice.sound, spec.min_distance)
		ma.sound_set_max_distance(&voice.sound, spec.max_distance)
	}
	ma.sound_start(&voice.sound)
}

// Every frame, menu included: the listener follows the camera, finished
// voices are reaped, and the footstep cadence runs. Reaping here keeps every
// sound_uninit on the main thread, never racing the mixer.
update_audio :: proc(dt: f32) {
	if !audio.ok do return

	forward := camera_forward()
	ma.engine_listener_set_position(
		&audio.engine,
		0,
		camera.position.x,
		camera.position.y,
		camera.position.z,
	)
	ma.engine_listener_set_direction(&audio.engine, 0, forward.x, forward.y, forward.z)

	for kind in Audio_Event_Kind {
		audio.cooldown[kind] = max(audio.cooldown[kind] - dt, 0)
	}

	for &v in audio.voices {
		if v.in_use && ma.sound_at_end(&v.sound) {
			ma.sound_uninit(&v.sound)
			v.in_use = false
		}
	}

	update_footsteps(dt)
}

// A scene change is a hard cut: gunfire from the match must not keep ringing
// through the menu or the range. Interface chrome is spared -- it narrates the
// transition itself. The loops are the scene's own and handled below. Logged
// so the headless E2E can see the cut land.
audio_stop_effects :: proc() {
	if !audio.ok do return
	stopped := 0
	for &v in audio.voices {
		if !v.in_use || v.chrome do continue
		ma.sound_uninit(&v.sound)
		v.in_use = false
		stopped += 1
	}
	if cli.audio_log && stopped > 0 {
		log.infof("AUDIO: scene cut, {} voices stopped", stopped)
	}
}

// Which looping tracks a scene wants. Called from enter_scene, the one place
// scene transitions happen; the benchmark writes the scene directly but never
// initialises audio, so the bypass is moot.
audio_scene_music :: proc(next: Scene) {
	switch next {
	case .Menu, .Mode_Select, .Team_Select, .Connecting:
		audio_loop_play(&audio.music, MENU_MUSIC, .Music)
		audio_loop_stop(&audio.ambient)
	case .Playing, .Practice:
		audio_loop_stop(&audio.music)
		audio_loop_play(&audio.ambient, AMBIENT_TRACK, .Ambient)
	case .Match_End:
		audio_loop_stop(&audio.music)
		audio_loop_stop(&audio.ambient)
	}
}

audio_apply_volumes :: proc() {
	if !audio.ok do return
	ma.engine_set_volume(&audio.engine, audio_settings.master)
	ma.sound_group_set_volume(&audio.groups[.Music], audio_settings.music)
	ma.sound_group_set_volume(&audio.groups[.Effects], audio_settings.effects)
	ma.sound_group_set_volume(&audio.groups[.Ambient], audio_settings.ambient)
}

// The audio half of the INI parser. Separate from apply_setting_key on
// purpose: that one stamps preset = .Custom on every key it knows, and a
// volume change must not turn the render preset custom.

// ------------------------------------------------------------------ loops

@(private = "file")
audio_loop_play :: proc(l: ^Audio_Loop, track: string, bus: Audio_Bus) {
	if !audio.ok do return
	if l.ok && l.path == track do return
	audio_loop_stop(l)

	flags: ma.sound_flags = {.STREAM, .NO_SPATIALIZATION}
	if r := ma.sound_init_from_file(
		&audio.engine,
		audio_path(track),
		flags,
		&audio.groups[bus],
		nil,
		&l.sound,
	); r != .SUCCESS {
		log.warnf("Audio: cannot stream {} ({})", track, r)
		return
	}
	ma.sound_set_looping(&l.sound, true)
	ma.sound_start(&l.sound)
	l.ok = true
	l.path = track
	if cli.audio_log do log.infof("AUDIO: loop {}", track)
}

@(private = "file")
audio_loop_stop :: proc(l: ^Audio_Loop) {
	if !l.ok do return
	ma.sound_uninit(&l.sound)
	l.ok = false
	l.path = ""
}

// -------------------------------------------------------------- internals

@(private = "file")
audio_path :: proc(rel: string) -> cstring {
	// Consumed synchronously inside the miniaudio call, so the temp
	// allocator's frame lifetime is enough.
	return strings.clone_to_cstring(fmt.tprintf("%s/%s", SOUND_DIR, rel), context.temp_allocator)
}

@(private = "file")
pick_variant :: proc(variants: ^[MAX_VARIANTS]Audio_Template) -> ^ma.sound {
	count := 0
	for t in variants {
		if t.ok do count += 1
	}
	if count == 0 do return nil
	pick := rand.int_max(count)
	for &t in variants {
		if !t.ok do continue
		if pick == 0 do return &t.sound
		pick -= 1
	}
	return nil
}

@(private = "file")
audio_preload :: proc() {
	loaded, missing := 0, 0
	for kind in Audio_Event_Kind {
		l, m := load_variants(AUDIO_BANK[kind].files, AUDIO_BANK[kind].bus, &audio.templates[kind])
		loaded += l
		missing += m
	}
	for w in 0 ..< game.WEAPON_COUNT {
		l, m := load_variants(WEAPON_FIRE_FILES[w], AUDIO_BANK[.Fire].bus, &audio.weapon_fire[w])
		loaded += l
		missing += m
	}
	log.infof("Audio: engine up, {} sounds loaded, {} missing", loaded, missing)
}

@(private = "file")
load_variants :: proc(
	files: []string,
	bus: Audio_Bus,
	out: ^[MAX_VARIANTS]Audio_Template,
) -> (
	loaded, missing: int,
) {
	for f, i in files {
		if i >= MAX_VARIANTS {
			log.warnf("Audio: more than {} variants, ignoring {}", MAX_VARIANTS, f)
			break
		}
		// Synchronous decode: the cstring is consumed inside the call, and
		// emits later never touch the disk.
		r := ma.sound_init_from_file(
			&audio.engine,
			audio_path(f),
			{.DECODE},
			&audio.groups[bus],
			nil,
			&out[i].sound,
		)
		if r != .SUCCESS {
			log.warnf("Audio: missing {}", f)
			missing += 1
			continue
		}
		out[i].ok = true
		loaded += 1
	}
	return
}

// The footstep cadence: a distance accumulator instead of animation events.
// Steps come from actual ground covered, so speed changes shift the rhythm
// the way feet would.
@(private = "file")
update_footsteps :: proc(dt: f32) {
	if !scene_playing() || dt <= 0 {
		audio.local_travelled = 0
		for &f in audio.feet do f.seen = false
		return
	}

	speed := physics.horizontal_speed(player.body.velocity)
	if player.alive && player.body.on_ground && speed >= FOOTSTEP_MIN_SPEED {
		audio.local_travelled += speed * dt
		if audio.local_travelled >= FOOTSTEP_STRIDE {
			audio.local_travelled -= FOOTSTEP_STRIDE
			audio_emit({kind = .Footstep, local = true})
		}
	} else {
		audio.local_travelled = 0
	}

	// Remote pawns walk the same accumulator over their interpolated drawn
	// positions -- what the player sees is what they hear. Sneaking remotes
	// move slowly and fall under the same threshold, which is the point.
	drawn_now: [game.MAX_PAWNS]bool
	for i in 0 ..< remote.drawn_count {
		d := remote.drawn[i]
		drawn_now[d.id] = true
		f := &audio.feet[d.id]
		if !f.seen {
			f^ = {
				prev = d.position,
				seen = true,
			}
			continue
		}
		delta := d.position - f.prev
		f.prev = d.position
		if linalg.length(delta) > REMOTE_TELEPORT {
			f.travelled = 0
			continue
		}
		// Bots wander below a human's sneak speed, so the human threshold
		// would keep every bot silent. Bots do not sneak; their gait is
		// simply audible.
		min_speed := d.is_bot ? f32(BOT_SPEED) * 0.6 : FOOTSTEP_MIN_SPEED
		speed_h := physics.horizontal_speed(delta) / dt
		airborne := abs(delta.z) / dt > REMOTE_AIRBORNE_VZ
		if speed_h >= min_speed && !airborne {
			f.travelled += speed_h * dt
			if f.travelled >= FOOTSTEP_STRIDE {
				f.travelled -= FOOTSTEP_STRIDE
				audio_emit({kind = .Footstep, pos = d.position})
			}
		} else {
			f.travelled = 0
		}
	}
	for &f, id in audio.feet {
		if !drawn_now[id] do f.seen = false
	}
}
