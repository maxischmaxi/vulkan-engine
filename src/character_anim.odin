package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "game"

// Poses the character skeleton: a clip and a time in, one matrix per joint out.
//
// The animation library this feeds on has no shooter in it -- no aim, no
// reload, no crouch, no death, and no run. What it does have is eight walk
// loops covering every direction, which is exactly the shape of a shooter's
// lower body, so the locomotion blend is built on those and the missing pieces
// become poses this file defines rather than clips it plays.

// Where the mannequin's nose points in model space, as a yaw offset in degrees.
// The engine measures yaw from +X; the rig faces somewhere else, and the glTF
// up-axis convention says nothing about which way an artist pointed a character.
//
// Measured rather than assumed, off the bind pose the converter writes: the toe
// joint sits 15 cm in front of the ankle along glTF +Z, and the axis change maps
// +Z onto -Y, so the model looks down -Y and needs a quarter turn to face +X.
CHARACTER_FACING_OFFSET :: f32(90)

// The mannequin's own height, so the instance transform can scale a pawn's hull
// height onto it. Taken from the skin bounds at load rather than written here,
// but the standing player is what the model was picked to match.
character_model_height :: proc() -> f32 {
	return character_skin.bounds_max.z - character_skin.bounds_min.z
}

// ----------------------------------------------------------------------- aim

// Model space again: the character faces -Y with +Z up, so looking up has to
// carry -Y toward +Z. A positive turn about +X does the opposite -- it takes
// -Y down to -Z -- so the axis is -X and the engine's positive pitch (up) comes
// out as up. One axis, one sign, both derived from the bind pose the converter
// wrote rather than from which way a bone happens to point.
AIM_PITCH_AXIS :: [3]f32{-1, 0, 0}

// Nobody bends this far, and a player looking straight down would otherwise
// fold the character in half. The head stops following well before the camera
// does, which is also what every shooter does.
AIM_PITCH_LIMIT :: f32(55)

// How the aim is spread down the spine. The shares sum to 1, so the head ends
// up at the full angle and everything below it leans into the movement instead
// of the neck snapping alone.
AIM_PITCH_JOINTS := [?]struct {
	name:  string,
	share: f32,
} {
	{"spine_01", 0.15},
	{"spine_02", 0.25},
	{"spine_03", 0.25},
	{"neck_01", 0.15},
	{"Head", 0.20},
}

// Resolved from names once at load, because a per-frame name lookup over 65
// joints for five hits would be five string compares per joint per character.
aim_pitch_share: [MAX_SKELETON_JOINTS]f32

@(private = "file")
build_aim_shares :: proc() {
	aim_pitch_share = {}
	total := f32(0)
	for entry in AIM_PITCH_JOINTS {
		aim_pitch_share[skeleton_joint_index(entry.name)] = entry.share
		total += entry.share
	}
	if abs(total - 1) > 1e-3 {
		log.panicf("aim pitch shares sum to {}, not 1", total)
	}
}

// Position, facing and hull height into the matrix the vertex shader applies
// after skinning. Scale is uniform: squashing a character to fit a shorter hull
// would be visible long before the hull mismatch is.
character_transform :: proc(position: [3]f32, yaw: f32, height: f32) -> linalg.Matrix4f32 {
	scale := height / character_model_height()
	angle := math.to_radians(yaw + CHARACTER_FACING_OFFSET)
	c, s := math.cos(angle), math.sin(angle)

	m: linalg.Matrix4f32 = 1
	m[0, 0] = c * scale
	m[0, 1] = -s * scale
	m[1, 0] = s * scale
	m[1, 1] = c * scale
	m[2, 2] = scale
	m[0, 3] = position.x
	m[1, 3] = position.y
	m[2, 3] = position.z
	return m
}

// ---------------------------------------------------------- the clip roster

// The blend space is eight directions 45 degrees apart, counter-clockwise from
// straight ahead. The order is load-bearing -- the runtime indexes into it by
// angle -- and matches DIRECTIONS in tools/convert_characters.py.
LOCOMOTION_DIRECTIONS :: 8

LOCOMOTION_NAMES := [LOCOMOTION_DIRECTIONS]string {
	"Fwd",
	"Fwd_L",
	"L",
	"Bwd_L",
	"Bwd",
	"Bwd_R",
	"R",
	"Fwd_R",
}

// The run tier is the library's zombie set. The legs under it are an ordinary
// eight-way run and the arms get replaced by the weapon pose, which is what
// makes it usable -- and it is the only run the pack has.
Locomotion_Clips :: struct {
	walk: [LOCOMOTION_DIRECTIONS]Anim_Clip,
	run:  [LOCOMOTION_DIRECTIONS]Anim_Clip,
}

locomotion: Locomotion_Clips

// Resolved once, because find_clip is a map lookup on a string and this would
// otherwise run four times per character per frame.
character_anim_init :: proc() {
	for name, i in LOCOMOTION_NAMES {
		locomotion.walk[i] = find_clip(
			strings.concatenate({"Walk_", name, "_Loop"}, context.temp_allocator),
		)
		locomotion.run[i] = find_clip(
			strings.concatenate({"Zombie_Run_", name, "_Loop"}, context.temp_allocator),
		)
	}
	weapon_hold_clip = find_clip(WEAPON_HOLD_CLIP)
	crouch_pose_clip = find_clip(CROUCH_POSE_CLIP)
	hit_reaction_clip = find_clip(HIT_REACTION_CLIP)
	weapon_hand_joint = skeleton_joint_index("hand_r")
	build_aim_shares()
	build_upper_body_mask()
	free_all(context.temp_allocator)
}

// ------------------------------------------------------- holding the weapon

// The library contains no aim, no reload and no weapon of any kind -- but a
// drawn bow is the same shape as a shouldered rifle: the left arm runs out along
// the line of fire, the right hand sits back at the body, the shoulders are
// square. Its first frame is taken as a pose and laid over the walk's upper
// body, which is the ordinary way a shooter is built and also what makes the
// run tier usable, since it replaces the zombie arms it came with.
WEAPON_HOLD_CLIP :: "Bow_Aim_Neutral"

weapon_hold_clip: Anim_Clip

// The joint the weapon hangs off, resolved once by name.
weapon_hand_joint: int

// Turns the mannequin's hand frame into the one the weapon meshes were baked
// against. The two rigs come from different packs -- the world weapons are
// anchored to the retro arms' hand_item_r bone, the character's hand is
// Quaternius' hand_r -- and nothing makes those agree, so the difference is
// measured off a screenshot and written down here. Rotation first about the
// forearm, then the grip offset in the hand's own frame.
WEAPON_GRIP_EULER :: [3]f32{0, 0, -90}
WEAPON_GRIP_OFFSET :: [3]f32{0, 0.02, 0}

@(private = "file")
weapon_grip_matrix :: proc() -> linalg.Matrix4f32 {
	rotation :=
		linalg.matrix4_rotate_f32(math.to_radians(WEAPON_GRIP_EULER.z), {0, 0, 1}) *
		linalg.matrix4_rotate_f32(math.to_radians(WEAPON_GRIP_EULER.y), {0, 1, 0}) *
		linalg.matrix4_rotate_f32(math.to_radians(WEAPON_GRIP_EULER.x), {1, 0, 0})
	return rotation * linalg.matrix4_translate_f32(WEAPON_GRIP_OFFSET)
}

// The joint the upper body is cut at. Everything from here up holds the weapon;
// everything below keeps walking.
UPPER_BODY_ROOT :: "spine_02"

// The joint below the cut, blended half way, so the seam is a lean rather than
// a crease at the waist.
UPPER_BODY_BLEND :: "spine_01"

upper_body_mask: [MAX_SKELETON_JOINTS]f32

// Derived from the hierarchy rather than listed by name. The upper body is 45
// of the 65 joints once the fingers are counted, and a list that long would be
// wrong the first time the rig changed and silent about it.
@(private = "file")
build_upper_body_mask :: proc() {
	upper_body_mask = {}
	root := skeleton_joint_index(UPPER_BODY_ROOT)
	upper_body_mask[root] = 1
	upper_body_mask[skeleton_joint_index(UPPER_BODY_BLEND)] = 0.5

	// Parents come before children, so one forward pass inherits the whole
	// subtree.
	for joint, i in character_skeleton.joints {
		if i <= root || joint.parent < 0 do continue
		if upper_body_mask[joint.parent] == 1 do upper_body_mask[i] = 1
	}
}

// Replaces, rather than adds to, the upper body's rotations. Additive would
// leave the arms swinging on top of the hold, which is exactly what carrying a
// rifle stops a person doing.
@(private = "file")
overlay_weapon_hold :: proc(blend: ^Pose_Blend, weight: f32) {
	if weight <= 0 do return

	sample_clip(weapon_hold_clip, 0, blend.scratch)
	for i in 0 ..< len(blend.rotations) {
		w := upper_body_mask[i] * weight
		if w <= 0 do continue
		blend.rotations[i] = linalg.quaternion_slerp_f32(blend.rotations[i], blend.scratch[i], w)
	}
}

// -------------------------------------------------------------- crouching

// There is no crouch clip either -- but IdleToLay passes through a crouch on
// its way to the floor, and at this point in it the head sits at 0.75 m, which
// is CROUCH_EYE_HEIGHT to the centimetre. Measured off the baked skeleton, not
// eyeballed; if the clip roster ever changes, that measurement is what has to be
// taken again.
CROUCH_POSE_CLIP :: "IdleToLay"
CROUCH_POSE_PHASE :: f32(42.0 / 90.0)

// Long enough not to flicker when a player spams the key, short enough to still
// read as ducking rather than sinking.
CROUCH_BLEND_TIME :: f32(0.14)

crouch_pose_clip: Anim_Clip

// The lower body: the complement of the upper-body mask, which makes spine_01
// the half-and-half joint in both directions and lets a crouching player still
// hold the weapon level.
@(private = "file")
overlay_crouch :: proc(blend: ^Pose_Blend, weight: f32) {
	if weight <= 0 do return

	motion := sample_clip(crouch_pose_clip, CROUCH_POSE_PHASE, blend.scratch)
	for i in 0 ..< len(blend.rotations) {
		w := (1 - upper_body_mask[i]) * weight
		if w <= 0 do continue
		blend.rotations[i] = linalg.quaternion_slerp_f32(blend.rotations[i], blend.scratch[i], w)
	}
	// The pelvis translation has to come along or the legs would fold under a
	// body that stayed at standing height.
	blend.motion = linalg.lerp(blend.motion, motion, weight)
}

// ------------------------------------------------------------ taking a hit

// Hit_Knockback, laid over the upper body while it decays. Whole-body would
// fight the locomotion for the legs, and a player who flinches out of their own
// footing reads as a bug rather than as a hit.
HIT_REACTION_CLIP :: "Hit_Knockback"

// The clip is a full stagger with the arms thrown wide -- authored for a melee
// game, and at anything like full weight it throws the weapon hold away and the
// character reads as surrendering rather than as being shot. A third of it is a
// flinch, which is what this is for.
HIT_REACTION_WEIGHT :: f32(0.35)

// And it is cut short: the tail of the stagger is the part that looks least
// like getting shot, and under sustained fire a hit lands long before the last
// one has played out.
HIT_REACTION_TIME :: f32(0.35)

hit_reaction_clip: Anim_Clip

@(private = "file")
overlay_hit :: proc(blend: ^Pose_Blend, elapsed: f32) {
	if elapsed < 0 || elapsed >= HIT_REACTION_TIME do return

	duration := f32(hit_reaction_clip.frame_count - 1) / hit_reaction_clip.fps
	phase := duration > 0 ? elapsed / duration : 0
	// Fades out across the window, so it ends by blending to nothing rather
	// than snapping back to the walk.
	weight := HIT_REACTION_WEIGHT * (1 - elapsed / HIT_REACTION_TIME)

	sample_clip(hit_reaction_clip, phase, blend.scratch)
	for i in 0 ..< len(blend.rotations) {
		w := upper_body_mask[i] * weight
		if w <= 0 do continue
		blend.rotations[i] = linalg.quaternion_slerp_f32(blend.rotations[i], blend.scratch[i], w)
	}
}

// ---------------------------------------------------------------- sampling

// Where a phase lands in a clip: the two frames that bracket it and the blend
// between them. Phase runs 0..1 over the clip; a looping clip wraps, a one-shot
// holds its last frame.
@(private = "file")
clip_frames :: proc(clip: Anim_Clip, phase: f32) -> (a, b: int, blend: f32) {
	if clip.frame_count <= 1 {
		return int(clip.first_frame), int(clip.first_frame), 0
	}

	segments := f32(clip.frame_count - 1)
	t := phase
	if clip.loop {
		t = t - math.floor(t)
	} else {
		t = clamp(t, 0, 1)
	}

	position := t * segments
	index := int(position)
	if index >= int(segments) {
		index = int(segments) - 1
		blend = 1
	} else {
		blend = position - f32(index)
	}

	a = int(clip.first_frame) + index
	b = a + 1
	return
}

// One clip at one phase, as local joint rotations plus the motion joint's
// translation. Writes into the caller's buffer so a blend can accumulate
// without allocating.
sample_clip :: proc(clip: Anim_Clip, phase: f32, rotations: []quaternion128) -> (motion: [3]f32) {
	joint_count := skeleton_joint_count()
	a, b, blend := clip_frames(clip, phase)

	s := &character_skeleton
	base_a := a * joint_count
	base_b := b * joint_count
	for i in 0 ..< joint_count {
		rotations[i] = linalg.quaternion_slerp_f32(s.rotations[base_a + i], s.rotations[base_b + i], blend)
	}
	return linalg.lerp(s.motion[a], s.motion[b], blend)
}

// Accumulates a weighted mix of clips one at a time.
//
// Blending n poses at once would need n buffers. Folding them in sequence needs
// two, and lands in the same place: each clip is pulled in by its own share of
// the weight admitted so far, so after the last one every clip is represented in
// the proportion it was given. The weights must sum to 1, which is what the
// caller computes them to do.
Pose_Blend :: struct {
	rotations: []quaternion128,
	motion:    [3]f32,
	scratch:   []quaternion128,
	admitted:  f32, // weight folded in so far
}

make_pose_blend :: proc(allocator := context.temp_allocator) -> Pose_Blend {
	count := skeleton_joint_count()
	return {
		rotations = make([]quaternion128, count, allocator),
		scratch = make([]quaternion128, count, allocator),
	}
}

blend_clip :: proc(blend: ^Pose_Blend, clip: Anim_Clip, phase, weight: f32) {
	if weight <= 1e-4 do return

	motion := sample_clip(clip, phase, blend.scratch)
	blend.admitted += weight

	// The first clip is copied rather than blended: there is nothing to blend
	// against yet, and weight/admitted would be 1 anyway.
	if blend.admitted <= weight + 1e-6 {
		copy(blend.rotations, blend.scratch)
		blend.motion = motion
		return
	}

	t := weight / blend.admitted
	for i in 0 ..< len(blend.rotations) {
		blend.rotations[i] = linalg.quaternion_slerp_f32(blend.rotations[i], blend.scratch[i], t)
	}
	blend.motion = linalg.lerp(blend.motion, motion, t)
}

// ------------------------------------------------------------------- posing

// Local rotations into the matrices the shader multiplies a vertex by.
//
// Two passes over one array. The first walks the hierarchy -- parents come
// before children in the file, so a single forward pass is enough -- and leaves
// each joint's model-space transform in place. The second folds in the inverse
// bind matrix, which has to happen after, because the children needed the plain
// model-space transform of their parent, not the skinning one.
build_joint_matrices :: proc(
	rotations: []quaternion128,
	motion: [3]f32,
	pitch: f32,
	out: []linalg.Matrix4f32,
) -> (
	weapon_hand: linalg.Matrix4f32,
) {
	s := &character_skeleton
	angle := math.to_radians(clamp(pitch, -AIM_PITCH_LIMIT, AIM_PITCH_LIMIT))

	for joint, i in s.joints {
		translation := joint.rest_translation
		if i == s.motion_joint {
			translation = motion
		}
		local := linalg.matrix4_from_trs_f32(translation, rotations[i], {1, 1, 1})
		out[i] = joint.parent < 0 ? local : out[joint.parent] * local

		// Aim, applied here rather than after the walk so the children inherit
		// it: bending the spine has to carry the neck, the head and both arms
		// with it, and by the time the loop reaches them out[parent] is what
		// they read.
		if share := aim_pitch_share[i]; share != 0 {
			out[i] = pivot_rotation(out[i], angle * share)
		}
	}

	// Taken before the inverse bind is folded in. A skinning matrix maps a
	// bind-pose vertex to where it ended up; hanging a weapon off the hand
	// wants the hand's own transform, which is what this still is.
	weapon_hand = out[weapon_hand_joint]

	for joint, i in s.joints {
		out[i] = out[i] * joint.inverse_bind
	}
	return
}

// Rotates a joint about its own origin, around the axis that pitches the model
// space forward direction up and down.
//
// A model-space pivot rather than a rotation in the bone's local frame. Which
// local axis a spine bone pitches around is a property of how the rig was
// authored -- bone roll, parent order, which way the exporter pointed the
// bone -- and getting it wrong bends the character sideways. In model space
// there is one axis and one sign, and both are checked once against a picture.
@(private = "file")
pivot_rotation :: proc(m: linalg.Matrix4f32, angle: f32) -> linalg.Matrix4f32 {
	if angle == 0 do return m

	origin := [3]f32{m[0, 3], m[1, 3], m[2, 3]}
	rotation := linalg.matrix4_rotate_f32(angle, AIM_PITCH_AXIS)

	// translate(origin) * rotate * translate(-origin) * m, written out: the
	// rotation happens about the joint rather than about the character's feet.
	shifted := m
	shifted[0, 3] = 0
	shifted[1, 3] = 0
	shifted[2, 3] = 0

	result := rotation * shifted
	result[0, 3] = origin.x
	result[1, 3] = origin.y
	result[2, 3] = origin.z
	return result
}

// ------------------------------------------------------------------ per pawn

// What survives between frames. It cannot live in remote.drawn, which is
// rebuilt every frame and indexed by draw order rather than by pawn: the walk
// phase has to keep running across frames, and a pawn that leaves the screen
// for a moment must not come back mid-stride from somebody else's slot.
Character_Anim :: struct {
	phase:      f32, // position in the walk cycle, 0..1, never reset while moving
	idle_phase: f32, // its own cycle, so standing still does not inherit a stride
	speed:      f32, // low-passed, because the snapshot pair steps rather than glides
	crouch:     f32, // 0 standing, 1 ducked, eased between
	hit_time:   f32, // seconds into the flinch, negative when not flinching
	health:     u8, // last seen, to notice it dropping
	seen:       bool, // whether health above means anything yet
	active:     bool, // cleared each frame, set by whoever draws this pawn
}

character_anims: [game.MAX_PAWNS]Character_Anim

// Everything drawing a character needs to say about it. A struct rather than
// eight parameters because the two callers -- networked remotes and local bots
// -- fill it from completely different places.
Character_Draw :: struct {
	id:       int,
	position: [3]f32,
	yaw:      f32,
	pitch:    f32,
	velocity: [3]f32,
	height:   f32,
	team:      game.Team,
	weapon:    int, // index into game.WEAPONS
	crouching: bool,
	health:    u8,
}

// The third-person mesh for a weapon: the same gun as the viewmodel, without
// the first-person arms welded on. The viewmodel names are the source of truth,
// so a weapon added to the table gets its world mesh for free -- but the mesh
// has to be in MESH_FILES, which is what the ok return guards.
world_weapon_mesh :: proc(weapon: int) -> (name: string, ok: bool) {
	if weapon < 0 || weapon >= game.WEAPON_COUNT do return "", false
	view := game.WEAPONS[weapon].model
	if !strings.has_prefix(view, "view_") do return "", false
	return strings.concatenate({"world_", view[len("view_"):]}, context.temp_allocator), true
}

// A slot that went a frame without being drawn is dead, respawning or out of
// the snapshot. Clearing its phase is what stops the next pawn to land on that
// id from starting mid-stride with somebody else's footing.
character_begin_pawns :: proc() {
	for &anim in character_anims {
		if !anim.active do anim = {hit_time = -1}
		anim.active = false
	}
}

// Below this a pawn is standing still as far as the legs are concerned. Well
// under a walk, well over the jitter the derived velocity carries.
IDLE_SPEED :: f32(0.35)

// How fast the smoothed speed chases the measured one. The snapshot pair only
// updates when the interpolation window moves on, so the raw value arrives in
// steps; without this the run blend would visibly stutter at the seams.
SPEED_SMOOTHING :: f32(12)

// Poses one pawn and hands it to the renderer.
submit_character :: proc(draw: Character_Draw) {
	transform := character_transform(draw.position, draw.yaw, draw.height)
	joints, ok := character_reserve(transform, draw.team)
	if !ok do return

	anim := &character_anims[draw.id]
	anim.active = true
	dt := game.clock.frame_dt

	target := draw.crouching ? f32(1) : 0
	step := CROUCH_BLEND_TIME > 0 ? dt / CROUCH_BLEND_TIME : 1
	anim.crouch += clamp(target - anim.crouch, -step, step)

	// A flinch is cued by health falling, which is the only damage signal the
	// snapshot carries for somebody else's pawn.
	if anim.seen && draw.health < anim.health {
		anim.hit_time = 0
	} else if anim.hit_time >= 0 {
		anim.hit_time += dt
	}
	anim.health = draw.health
	anim.seen = true

	// Horizontal only: falling is not walking, and a jump would otherwise crank
	// the walk cycle up to a sprint on the way down.
	flat := [3]f32{draw.velocity.x, draw.velocity.y, 0}
	measured := linalg.length(flat)
	anim.speed = linalg.lerp(anim.speed, measured, min(1, dt * SPEED_SMOOTHING))

	blend := make_pose_blend()
	moving := anim.speed > IDLE_SPEED

	if moving {
		stride := blend_locomotion(&blend, anim.phase, anim.speed, flat, draw.yaw)
		// The cycle is driven by distance, not by time. The converter measured
		// how far each clip's root travels in one cycle, so advancing by
		// speed/stride puts the foot down where the ground actually is -- foot
		// sliding is ruled out rather than tuned away.
		if stride > 0.01 {
			anim.phase = math.mod(anim.phase + dt * anim.speed / stride, 1)
		}
	} else {
		idle := find_clip("Idle_FoldArms_Loop")
		seconds := f32(idle.frame_count - 1) / idle.fps
		if seconds > 0 {
			anim.idle_phase = math.mod(anim.idle_phase + dt / seconds, 1)
		}
		blend_clip(&blend, idle, anim.idle_phase, 1)
	}

	// Lower body first, then upper: the two masks are complements, so a ducked
	// player still holds the weapon level and a flinch still reads while they
	// are down there.
	overlay_crouch(&blend, anim.crouch)
	overlay_weapon_hold(&blend, 1)
	overlay_hit(&blend, anim.hit_time)

	hand := build_joint_matrices(blend.rotations, blend.motion, draw.pitch, joints)

	// The weapon rides the hand joint rather than being skinned: it is rigid,
	// so one matrix says everything about where it is.
	if mesh, has := world_weapon_mesh(draw.weapon); has {
		add_world_model(mesh, transform * hand * weapon_grip_matrix())
	}
}

// The eight-way blend space, at whichever of the two speed tiers the pawn is
// moving at. Returns the stride length of the mix, which is what drives the
// cycle.
@(private = "file")
blend_locomotion :: proc(
	blend: ^Pose_Blend,
	phase, speed: f32,
	flat: [3]f32,
	yaw: f32,
) -> f32 {
	// Direction in the pawn's own frame: 0 is straight ahead, +90 is to its
	// left, which is the order the clip roster is stored in.
	forward := game.yaw_forward_flat(yaw)
	left := [3]f32{-forward.y, forward.x, 0}
	angle := math.atan2(linalg.dot(flat, left), linalg.dot(flat, forward))

	sector := angle / (math.PI / 4)
	low := int(math.floor(sector))
	t := sector - math.floor(sector)
	i0 := ((low % LOCOMOTION_DIRECTIONS) + LOCOMOTION_DIRECTIONS) % LOCOMOTION_DIRECTIONS
	i1 := (i0 + 1) % LOCOMOTION_DIRECTIONS

	walk0, walk1 := locomotion.walk[i0], locomotion.walk[i1]
	run0, run1 := locomotion.run[i0], locomotion.run[i1]

	// Two neighbouring clips per tier is enough at 45 degrees apart, and it
	// halves the sampling against a four-corner blend.
	walk_stride := linalg.lerp(clip_stride(walk0), clip_stride(walk1), t)
	run_stride := linalg.lerp(clip_stride(run0), clip_stride(run1), t)
	walk_speed := linalg.lerp(clip_speed(walk0), clip_speed(walk1), t)
	run_speed := linalg.lerp(clip_speed(run0), clip_speed(run1), t)

	// Where this pawn sits between the speeds the two tiers were authored at.
	// Outside that range the clip simply plays faster or slower; the tier blend
	// only decides which gait it is.
	tier := f32(0)
	if run_speed > walk_speed {
		tier = clamp((speed - walk_speed) / (run_speed - walk_speed), 0, 1)
	}

	// One phase for all four: the clips are all authored with the same foot
	// down at the same point in the cycle, so sharing it is what keeps two
	// blended gaits from walking out of step with each other.
	blend_clip(blend, walk0, phase, (1 - tier) * (1 - t))
	blend_clip(blend, walk1, phase, (1 - tier) * t)
	blend_clip(blend, run0, phase, tier * (1 - t))
	blend_clip(blend, run1, phase, tier * t)

	return linalg.lerp(walk_stride, run_stride, tier)
}

@(private = "file")
clip_stride :: proc(clip: Anim_Clip) -> f32 {
	return linalg.length([3]f32{clip.displacement.x, clip.displacement.y, 0})
}

@(private = "file")
clip_speed :: proc(clip: Anim_Clip) -> f32 {
	seconds := f32(clip.frame_count - 1) / clip.fps
	return seconds > 0 ? clip_stride(clip) / seconds : 0
}
