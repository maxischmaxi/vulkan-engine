#!/usr/bin/env python3
"""Turns the Universal Animation Library glTF into models/mannequin.{skin,skel}.

Run through `just models`, never directly: it needs assets/ unpacked first.

Why a plain parser and not Blender, unlike convert_models.py: this file is a
glTF, and glTF already stores exactly what a skinned renderer wants -- inverse
bind matrices, four joint indices and four weights per vertex, one keyframe
track per joint. The pack is also free of everything that makes glTF hard
(verified: no sparse accessors, no interleaved buffer views, no matrix-form
nodes). Going through Blender would insert bone rolls and its own armature
conventions between the file and the engine, only to have to take them out
again. The Collada reader in convert_models.py exists for the same reason.

Two things this file knows that nothing else does:

  Axes. glTF is Y-up, the engine is Z-up, so (x, y, z) -> (x, -z, y). That is a
  rotation about X, not a mirror, so the triangle winding survives and the
  pipeline's COUNTER_CLOCKWISE culling holds. It is applied in exactly two
  places -- the bind-pose vertices, and the local transform of the one root
  joint -- because a bone's local transform is relative to its parent, so
  rotating the root rotates the whole skeleton with it and every other joint can
  stay in the space it was authored in.

  What the animations do not contain. There is no aim pose, no reload, no
  crouch, no death and no run anywhere in the 134 clips; the eight walk loops
  are the whole shooter-usable set, and the engine drives them faster rather
  than switching to a run clip. So the roster below is short on purpose -- but
  the format stores clips as ranges in one shared array, so adding a name costs
  the frames it brings and nothing else.
"""

import json
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GLB = ROOT / "assets" / "characters" / "UAL2.glb"
# The same library with root motion left in. Read for one number per clip: how
# far the root travels in one cycle. See measure_strides().
GLB_ROOT_MOTION = ROOT / "assets" / "characters" / "UAL2_RM.glb"
OUT = ROOT / "models"

SKEL_MAGIC = b"DSKL"
SKIN_MAGIC = b"DSKN"
VERSION = 1
NAME_LEN = 32

# Swatch grid for the character palette, the same trick the gun pack uses: the
# mannequin has no textures, so each material gets a constant UV at the centre
# of its own cell and the colour lives in the texture. Two cells today; the team
# colour itself is a material tint in Odin, not a swatch.
PALETTE_GRID = 2
PALETTE_CELLS = {"char_main": 0, "char_joints": 1}

# glTF material name -> engine material name.
MATERIAL_MAP = {"M_Main": "char_main", "M_Joints": "char_joints"}

# The eight directions of a locomotion blend space, counter-clockwise from
# forward at 45 degrees apart. The order is the one the runtime indexes into, so
# it is a sequence and not a set.
DIRECTIONS = ["Fwd", "Fwd_L", "L", "Bwd_L", "Bwd", "Bwd_R", "R", "Fwd_R"]

WALK_CLIPS = [f"Walk_{d}_Loop" for d in DIRECTIONS]

# The run tier. They are named for zombies and the arms hang like it, but the
# legs underneath are an ordinary eight-way run and the upper body is replaced
# by the weapon pose anyway -- so this is the run set the library is supposed
# not to have. At 4.09 m/s authored against the engine's 6.35 m/s sprint, the
# playback rate stays near 1.5 instead of the 6x a walk cycle would need.
RUN_CLIPS = [f"Zombie_Run_{d}_Loop" for d in DIRECTIONS]

# The clips the animation code plays outside the blend space. Everything else in
# the library is swordplay, farming and fishing.
EXTRA_CLIPS = [
    "A_TPose",
    "Idle_FoldArms_Loop",
    "Hit_Knockback",
    "Turn180_L",
    "Turn180_R",
    "StepUp",
    # The death animation the pack does not advertise as one: idle to lying
    # down, three seconds, ends flat on the floor.
    "IdleToLay",
    # And the weapon hold the pack does not advertise either. There is no aim
    # animation anywhere in the library, but a drawn bow is the same shape as a
    # shouldered rifle: left arm out along the barrel, right hand back at the
    # body, shoulders squared down the line of fire. Only its first frame is
    # used, as a pose to lay over the walk's upper body.
    "Bow_Aim_Neutral",
]

CLIPS = EXTRA_CLIPS + WALK_CLIPS + RUN_CLIPS

CLIP_LOOP = 1 << 0

# Every clip is resampled onto this grid. The library is authored at it, so the
# resample is an identity today and a safety net for anything added later.
FPS = 30.0

# The bone whose translation is animated. Verified across the whole library:
# every other joint holds its rest translation for every frame of every clip,
# which is what lets the format store one translation track instead of 65.
MOTION_JOINT_NAME = "pelvis"


# ------------------------------------------------------------------ glTF read


def load_glb(path):
    """(json, binary chunk) from a .glb."""
    data = path.read_bytes()
    magic, version, _total = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2:
        sys.exit(f"{path}: not a glTF 2.0 binary")

    gltf = None
    blob = b""
    offset = 12
    while offset < len(data):
        length, kind = struct.unpack_from("<I4s", data, offset)
        chunk = data[offset + 8 : offset + 8 + length]
        if kind == b"JSON":
            gltf = json.loads(chunk)
        elif kind == b"BIN\0":
            blob = chunk
        offset += 8 + length + (-length % 4)

    if gltf is None:
        sys.exit(f"{path}: no JSON chunk")
    return gltf, blob


COMPONENT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
COMPONENTS_PER = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def accessor(gltf, blob, index):
    """One accessor as a list of tuples. Sparse accessors and byte strides are
    rejected rather than handled: this pack has neither, and a silently wrong
    read is worse than a stop."""
    acc = gltf["accessors"][index]
    if "sparse" in acc:
        sys.exit(f"accessor {index} is sparse, which this reader does not do")

    view = gltf["bufferViews"][acc["bufferView"]]
    if "byteStride" in view:
        sys.exit(f"accessor {index} is interleaved, which this reader does not do")

    fmt, size = COMPONENT[acc["componentType"]]
    count = COMPONENTS_PER[acc["type"]]
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = size * count
    return [struct.unpack_from("<" + fmt * count, blob, start + i * stride) for i in range(acc["count"])]


# ------------------------------------------------------------------- 4x4 math
#
# Row-major lists of lists while computing, column-major on the way to disk --
# which is what both glTF and Odin store, so the write is a straight copy.


def mat_identity():
    return [[1.0 if r == c else 0.0 for c in range(4)] for r in range(4)]


def mat_mul(a, b):
    return [[sum(a[r][k] * b[k][c] for k in range(4)) for c in range(4)] for r in range(4)]


def mat_from_column_major(values):
    return [[values[c * 4 + r] for c in range(4)] for r in range(4)]


def mat_to_column_major(m):
    return [m[r][c] for c in range(4) for r in range(4)]


def mat_from_trs(translation, rotation, scale):
    x, y, z, w = rotation
    sx, sy, sz = scale
    return [
        [(1 - 2 * (y * y + z * z)) * sx, (2 * (x * y - z * w)) * sy, (2 * (x * z + y * w)) * sz, translation[0]],
        [(2 * (x * y + z * w)) * sx, (1 - 2 * (x * x + z * z)) * sy, (2 * (y * z - x * w)) * sz, translation[1]],
        [(2 * (x * z - y * w)) * sx, (2 * (y * z + x * w)) * sy, (1 - 2 * (x * x + y * y)) * sz, translation[2]],
        [0.0, 0.0, 0.0, 1.0],
    ]


# Y-up to Z-up, as a matrix and as the quaternion that says the same thing.
AXIS_FIX = [
    [1.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, -1.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 0.0, 1.0],
]
AXIS_FIX_INV = [
    [1.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, 1.0, 0.0],
    [0.0, -1.0, 0.0, 0.0],
    [0.0, 0.0, 0.0, 1.0],
]
AXIS_FIX_QUAT = (math.sin(math.pi / 4), 0.0, 0.0, math.cos(math.pi / 4))


def convert_point(p):
    return (p[0], -p[2], p[1])


def quat_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def quat_normalize(q):
    length = math.sqrt(sum(c * c for c in q))
    if length < 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    return tuple(c / length for c in q)


def quat_slerp(a, b, t):
    dot = sum(a[i] * b[i] for i in range(4))
    if dot < 0.0:
        b = tuple(-c for c in b)
        dot = -dot
    if dot > 0.9995:
        return quat_normalize(tuple(a[i] + (b[i] - a[i]) * t for i in range(4)))
    theta = math.acos(max(-1.0, min(1.0, dot)))
    sin_theta = math.sin(theta)
    wa = math.sin((1.0 - t) * theta) / sin_theta
    wb = math.sin(t * theta) / sin_theta
    return tuple(a[i] * wa + b[i] * wb for i in range(4))


# --------------------------------------------------------------------- rigging


class Rig:
    """The skin's joints, flattened into the arrays the engine reads."""

    def __init__(self, gltf, blob):
        skins = gltf.get("skins", [])
        if len(skins) != 1:
            sys.exit(f"expected exactly one skin, found {len(skins)}")
        skin = skins[0]

        self.nodes = gltf["nodes"]
        self.joints = skin["joints"]
        self.slot_of_node = {node: slot for slot, node in enumerate(self.joints)}

        # The skinned mesh node's own transform is ignored by the glTF spec, but
        # the armature holding the joints is not -- so it has to be identity, or
        # the whole skeleton would sit somewhere this file never accounts for.
        for node in gltf["scenes"][gltf.get("scene", 0)]["nodes"]:
            n = self.nodes[node]
            if node not in self.slot_of_node and any(k in n for k in ("translation", "rotation", "scale", "matrix")):
                sys.exit(f"scene root {n.get('name')!r} carries a transform this reader ignores")

        parent_of = {}
        for index, node in enumerate(self.nodes):
            for child in node.get("children", []):
                parent_of[child] = index

        self.names = []
        self.parents = []
        self.rest_translation = []
        self.rest_rotation = []
        for slot, node in enumerate(self.joints):
            n = self.nodes[node]
            if "matrix" in n:
                sys.exit(f"joint {n.get('name')!r} uses a matrix transform, which this reader does not do")
            scale = n.get("scale", [1.0, 1.0, 1.0])
            if max(abs(s - 1.0) for s in scale) > 1e-5:
                sys.exit(f"joint {n.get('name')!r} has a rest scale, which the format does not carry")

            parent_node = parent_of.get(node)
            parent = self.slot_of_node.get(parent_node, -1) if parent_node is not None else -1
            if parent >= slot:
                sys.exit("joints are not in parent-before-child order")

            translation = tuple(n.get("translation", [0.0, 0.0, 0.0]))
            rotation = quat_normalize(tuple(n.get("rotation", [0.0, 0.0, 0.0, 1.0])))
            # The root carries the Y-up to Z-up change for the whole skeleton;
            # see the module docstring.
            if parent < 0:
                translation = convert_point(translation)
                rotation = quat_mul(AXIS_FIX_QUAT, rotation)

            self.names.append(n.get("name", f"joint_{slot}"))
            self.parents.append(parent)
            self.rest_translation.append(translation)
            self.rest_rotation.append(rotation)

        # inverse_bind maps a model-space vertex into the joint's bind space, so
        # feeding it engine-space vertices means undoing the axis change first.
        raw = accessor(gltf, blob, skin["inverseBindMatrices"])
        self.inverse_bind = [mat_mul(mat_from_column_major(m), AXIS_FIX_INV) for m in raw]

        if MOTION_JOINT_NAME not in self.names:
            sys.exit(f"no {MOTION_JOINT_NAME!r} joint to carry the translation track")
        self.motion_joint = self.names.index(MOTION_JOINT_NAME)

    def count(self):
        return len(self.joints)

    def global_matrices(self, rotations, motion):
        """Model-space matrix per joint for one pose."""
        out = []
        for slot in range(self.count()):
            translation = self.rest_translation[slot]
            if slot == self.motion_joint:
                translation = motion
            local = mat_from_trs(translation, rotations[slot], (1.0, 1.0, 1.0))
            parent = self.parents[slot]
            out.append(local if parent < 0 else mat_mul(out[parent], local))
        return out


# ------------------------------------------------------------------ animation


class Clip:
    def __init__(self, name, rotations, motion, loop):
        self.name = name
        self.rotations = rotations  # [frame][joint] -> (x, y, z, w)
        self.motion = motion  # [frame] -> (x, y, z)
        self.loop = loop
        # How far the root travels in one cycle, in engine axes. Filled from the
        # root-motion library; zero for anything that does not move.
        self.displacement = (0.0, 0.0, 0.0)

    def frame_count(self):
        return len(self.rotations)

    def fix_hemispheres(self):
        """q and -q are the same rotation, and an exporter is free to flip
        between them from one key to the next -- this library does it about
        twice per clip. Interpolating across a flip sends the joint the long
        way round, so every track is walked once and made continuous."""
        flips = 0
        for joint in range(len(self.rotations[0])):
            for frame in range(1, len(self.rotations)):
                previous = self.rotations[frame - 1][joint]
                current = self.rotations[frame][joint]
                if sum(previous[i] * current[i] for i in range(4)) < 0.0:
                    self.rotations[frame][joint] = tuple(-c for c in current)
                    flips += 1
        return flips


def read_clip(gltf, blob, rig, animation):
    """One animation resampled onto the FPS grid, keeping only what the format
    stores: a rotation per joint plus the motion joint's translation."""
    name = animation["name"]
    samplers = animation["samplers"]

    times = None
    tracks_rotation = {}
    tracks_translation = {}
    for channel in animation["channels"]:
        target = channel["target"]
        slot = rig.slot_of_node.get(target["node"])
        if slot is None:
            continue
        sampler = samplers[channel["sampler"]]
        if sampler.get("interpolation", "LINEAR") != "LINEAR":
            sys.exit(f"{name}: {sampler.get('interpolation')} interpolation is not supported")

        stamps = [t[0] for t in accessor(gltf, blob, sampler["input"])]
        if times is None:
            times = stamps
        values = accessor(gltf, blob, sampler["output"])

        if target["path"] == "rotation":
            tracks_rotation[slot] = (stamps, [quat_normalize(v) for v in values])
        elif target["path"] == "translation":
            tracks_translation[slot] = (stamps, values)
        elif target["path"] == "scale":
            drift = max(max(abs(c - 1.0) for c in v) for v in values)
            if drift > 1e-4:
                sys.exit(f"{name}: joint {rig.names[slot]} is scaled, which the format does not carry")

    if not times:
        sys.exit(f"{name}: no keyframes")

    # Every joint that is not the motion joint has to hold its rest translation,
    # or the single translation track this format stores would drop movement on
    # the floor without saying so.
    for slot, (_stamps, values) in tracks_translation.items():
        if slot == rig.motion_joint:
            continue
        rest = rig.rest_translation[slot]
        if rig.parents[slot] < 0:
            values = [convert_point(v) for v in values]
        drift = max(max(abs(v[i] - rest[i]) for i in range(3)) for v in values)
        if drift > 1e-4:
            sys.exit(f"{name}: joint {rig.names[slot]} has an animated translation ({drift:.4f} m)")

    duration = times[-1]
    frame_count = max(2, int(round(duration * FPS)) + 1)

    rotations = []
    motion = []
    for frame in range(frame_count):
        t = duration * frame / (frame_count - 1)
        pose = []
        for slot in range(rig.count()):
            track = tracks_rotation.get(slot)
            if track is None:
                pose.append(rig.rest_rotation[slot])
                continue
            q = sample_rotation(track, t)
            if rig.parents[slot] < 0:
                q = quat_mul(AXIS_FIX_QUAT, q)
            pose.append(q)
        rotations.append(pose)

        track = tracks_translation.get(rig.motion_joint)
        motion.append(sample_vector(track, t) if track else rig.rest_translation[rig.motion_joint])

    return Clip(name, rotations, motion, name.endswith("_Loop"))


def measure_strides(clips):
    """One number per clip out of the root-motion library: the distance the root
    covers in a cycle, in engine axes.

    This is what lets the walk cycle be driven by distance instead of time. A
    stride length guessed in code has to be retuned for every clip and still
    leaves feet skating; measured here, the phase advances by
    `speed / stride` and the foot is on the ground where the ground is."""
    if not GLB_ROOT_MOTION.exists():
        print(f"  {GLB_ROOT_MOTION.name} missing -- strides default to zero")
        return

    gltf, blob = load_glb(GLB_ROOT_MOTION)
    nodes = gltf["nodes"]
    roots = {j for j in gltf["skins"][0]["joints"] if nodes[j].get("name") == "root"}
    by_name = {a["name"]: a for a in gltf.get("animations", [])}

    for clip in clips:
        animation = by_name.get(clip.name)
        if animation is None:
            continue
        for channel in animation["channels"]:
            target = channel["target"]
            if target["path"] != "translation" or target["node"] not in roots:
                continue
            values = accessor(gltf, blob, animation["samplers"][channel["sampler"]]["output"])
            first, last = convert_point(values[0]), convert_point(values[-1])
            clip.displacement = tuple(last[i] - first[i] for i in range(3))


def _bracket(stamps, t):
    """(index, blend) for t inside the stamp list, clamped at both ends."""
    if t <= stamps[0]:
        return 0, 0.0
    if t >= stamps[-1]:
        return len(stamps) - 1, 0.0
    low, high = 0, len(stamps) - 1
    while high - low > 1:
        mid = (low + high) // 2
        if stamps[mid] <= t:
            low = mid
        else:
            high = mid
    span = stamps[high] - stamps[low]
    return low, 0.0 if span <= 0 else (t - stamps[low]) / span


def sample_rotation(track, t):
    stamps, values = track
    index, blend = _bracket(stamps, t)
    if blend <= 0.0:
        return values[index]
    return quat_slerp(values[index], values[index + 1], blend)


def sample_vector(track, t):
    stamps, values = track
    index, blend = _bracket(stamps, t)
    if blend <= 0.0:
        return values[index]
    a, b = values[index], values[index + 1]
    return tuple(a[i] + (b[i] - a[i]) * blend for i in range(3))


# ----------------------------------------------------------------------- mesh


def swatch_uv(cell):
    """Centre of a palette cell, v running down the image."""
    col, row = cell % PALETTE_GRID, cell // PALETTE_GRID
    return ((col + 0.5) / PALETTE_GRID, (row + 0.5) / PALETTE_GRID)


def fallback_tangent(normal):
    """A unit tangent for UV-less swatch geometry: any stable direction not
    parallel to the normal, Gram-Schmidt orthogonalised. Same rule as the gun
    meshes, which have the same problem."""
    axis = (1.0, 0.0, 0.0) if abs(normal[0]) < 0.9 else (0.0, 0.0, 1.0)
    dot = sum(axis[i] * normal[i] for i in range(3))
    t = [axis[i] - normal[i] * dot for i in range(3)]
    length = math.sqrt(sum(c * c for c in t))
    if length < 1e-8:
        return (0.0, 1.0, 0.0)
    return tuple(c / length for c in t)


def normalize_weights(raw):
    """Four weights as bytes summing to exactly 255, so the shader's /255 lands
    on 1.0 and no vertex quietly shrinks toward the origin."""
    total = sum(raw)
    if total <= 0.0:
        return [255, 0, 0, 0]
    scaled = [w / total * 255.0 for w in raw]
    out = [int(round(w)) for w in scaled]
    # Hand the rounding error to the heaviest bone; it is the one that can
    # absorb a 1/255 change without moving the vertex anywhere visible.
    drift = 255 - sum(out)
    if drift:
        out[max(range(4), key=lambda i: scaled[i])] += drift
    return out


def read_mesh(gltf, blob, rig):
    """(vertices, indices, material names) in the engine's skinned layout."""
    meshes = gltf.get("meshes", [])
    if len(meshes) != 1:
        sys.exit(f"expected exactly one mesh, found {len(meshes)}")

    vertices = []
    indices = []
    materials = []

    for primitive in meshes[0]["primitives"]:
        if primitive.get("mode", 4) != 4:
            sys.exit("only triangle primitives are supported")

        gltf_name = gltf["materials"][primitive["material"]].get("name")
        if gltf_name not in MATERIAL_MAP:
            sys.exit(f"material {gltf_name!r} has no engine material -- see MATERIAL_MAP")
        name = MATERIAL_MAP[gltf_name]
        if name not in materials:
            materials.append(name)
        slot = materials.index(name)
        uv = swatch_uv(PALETTE_CELLS[name])

        attributes = primitive["attributes"]
        positions = accessor(gltf, blob, attributes["POSITION"])
        normals = accessor(gltf, blob, attributes["NORMAL"])
        joints = accessor(gltf, blob, attributes["JOINTS_0"])
        weights = accessor(gltf, blob, attributes["WEIGHTS_0"])

        base = len(vertices)
        for i in range(len(positions)):
            position = convert_point(positions[i])
            normal = convert_point(normals[i])
            length = math.sqrt(sum(c * c for c in normal))
            normal = tuple(c / length for c in normal) if length > 1e-8 else (0.0, 0.0, 1.0)
            for joint in joints[i]:
                if joint >= rig.count():
                    sys.exit(f"vertex {i} references joint {joint} of {rig.count()}")
            vertices.append(
                (
                    position,
                    normal,
                    fallback_tangent(normal),
                    1.0,
                    uv,
                    slot,
                    tuple(int(j) for j in joints[i]),
                    normalize_weights(weights[i]),
                )
            )

        for triangle in accessor(gltf, blob, primitive["indices"]):
            indices.append(base + triangle[0])

    return vertices, indices, materials


# ---------------------------------------------------------------------- write


def pack_name(name):
    raw = name.encode("ascii")
    if len(raw) >= NAME_LEN:
        sys.exit(f"name {name!r} does not fit in {NAME_LEN} bytes")
    return raw + b"\0" * (NAME_LEN - len(raw))


def write_skeleton(path, rig, clips):
    total_frames = sum(clip.frame_count() for clip in clips)

    blob = bytearray()
    blob += SKEL_MAGIC
    blob += struct.pack("<IIIIIII", VERSION, rig.count(), len(clips), rig.motion_joint, total_frames, 0, 0)

    for slot in range(rig.count()):
        blob += pack_name(rig.names[slot])
        blob += struct.pack("<i", rig.parents[slot])
        blob += struct.pack("<3f", *rig.rest_translation[slot])
        blob += struct.pack("<16f", *mat_to_column_major(rig.inverse_bind[slot]))

    first = 0
    for clip in clips:
        blob += pack_name(clip.name)
        blob += struct.pack("<IIfI", first, clip.frame_count(), FPS, CLIP_LOOP if clip.loop else 0)
        blob += struct.pack("<3f", *clip.displacement)
        blob += struct.pack("<f", 0.0) # pads the entry to 64 bytes
        first += clip.frame_count()

    for clip in clips:
        for pose in clip.rotations:
            for q in pose:
                blob += struct.pack("<4f", *q)
    for clip in clips:
        for t in clip.motion:
            blob += struct.pack("<3f", *t)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)
    print(
        f"  {path.name:22} {rig.count()} joints, {len(clips)} clips, "
        f"{total_frames} frames, {len(blob) / 1024:.0f} KiB"
    )


def write_skin(path, vertices, indices, materials, joint_count):
    lows = [min(v[0][i] for v in vertices) for i in range(3)]
    highs = [max(v[0][i] for v in vertices) for i in range(3)]

    blob = bytearray()
    blob += SKIN_MAGIC
    blob += struct.pack("<IIIII", VERSION, len(vertices), len(indices), len(materials), joint_count)
    blob += struct.pack("<3f", *lows)
    blob += struct.pack("<3f", *highs)
    for name in materials:
        blob += pack_name(name)
    for position, normal, tangent, sign, uv, slot, joints, weights in vertices:
        blob += struct.pack(
            "<3f3f4f2fI4B4B",
            *position,
            *normal,
            *tangent,
            sign,
            *uv,
            slot,
            *joints,
            *weights,
        )
    blob += struct.pack(f"<{len(indices)}I", *indices)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)
    size = tuple(round(highs[i] - lows[i], 3) for i in range(3))
    print(
        f"  {path.name:22} {len(vertices)} verts {len(indices) // 3} tris "
        f"size={size} m  materials={materials}"
    )


# ----------------------------------------------------------------------- test


def check_bind_pose(rig, vertices):
    """The rest pose times the inverse bind matrices has to come out as the
    identity, and skinning a vertex through it has to leave it where it is.

    This is the whole reason to have a self-test: it fails on a wrong matrix
    order, a wrong axis change, a transposed read or a joint listed out of
    hierarchy order -- every mistake this file can make -- and it fails here,
    before any of it reaches a vertex buffer."""
    matrices = rig.global_matrices(rig.rest_rotation, rig.rest_translation[rig.motion_joint])

    worst = 0.0
    for slot in range(rig.count()):
        product = mat_mul(matrices[slot], rig.inverse_bind[slot])
        for r in range(4):
            for c in range(4):
                worst = max(worst, abs(product[r][c] - (1.0 if r == c else 0.0)))
    if worst > 1e-4:
        sys.exit(f"bind pose does not invert: worst element off by {worst:.6f}")

    skinned_worst = 0.0
    for position, _n, _t, _s, _uv, _slot, joints, weights in vertices[::37]:
        out = [0.0, 0.0, 0.0]
        for joint, weight in zip(joints, weights):
            if weight == 0:
                continue
            m = mat_mul(matrices[joint], rig.inverse_bind[joint])
            w = weight / 255.0
            for r in range(3):
                out[r] += w * (m[r][0] * position[0] + m[r][1] * position[1] + m[r][2] * position[2] + m[r][3])
        skinned_worst = max(skinned_worst, max(abs(out[i] - position[i]) for i in range(3)))
    if skinned_worst > 1e-3:
        sys.exit(f"skinning the bind pose moves vertices by up to {skinned_worst:.6f} m")

    print(f"  bind pose verified: matrices within {worst:.2e}, vertices within {skinned_worst:.2e} m")


def main():
    if not GLB.exists():
        sys.exit(f"{GLB} missing -- run tools/extract_models.sh")

    gltf, blob = load_glb(GLB)
    rig = Rig(gltf, blob)

    by_name = {a["name"]: a for a in gltf.get("animations", [])}
    missing = [name for name in CLIPS if name not in by_name]
    if missing:
        sys.exit(f"the library has no clip named {missing}")
    clips = [read_clip(gltf, blob, rig, by_name[name]) for name in CLIPS]

    vertices, indices, materials = read_mesh(gltf, blob, rig)

    print("characters:")
    flips = sum(clip.fix_hemispheres() for clip in clips)
    print(f"  {flips} quaternion sign flips made continuous")
    measure_strides(clips)
    for clip in clips:
        stride = math.sqrt(sum(c * c for c in clip.displacement))
        if stride > 0.01:
            seconds = (clip.frame_count() - 1) / FPS
            print(f"    {clip.name:24} {stride:.2f} m per cycle, {stride / seconds:.2f} m/s")

    check_bind_pose(rig, vertices)
    write_skin(OUT / "mannequin.skin", vertices, indices, materials, rig.count())
    write_skeleton(OUT / "mannequin.skel", rig, clips)


if __name__ == "__main__":
    main()
