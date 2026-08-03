#!/usr/bin/env -S blender -b -P
"""Turns the asset archives into models/*.mesh, the engine's own mesh format.

Run through `just models`, never directly: it needs assets/ unpacked and the
textures built first.

Why a converter at all, rather than loading FBX or glTF at runtime: the engine
has exactly one vertex layout (src/vertex.odin), and everything interesting
about an import -- units, axes, which mesh belongs to which texture, what the
weapon's rest pose is -- is a decision that only has to be made once. Making it
here leaves the runtime with a file it can memcpy into a vertex buffer.

Two things this file knows that nothing else does:

  Axes. The weapon scenes are built for a camera at the origin looking down +X
  with +Z up. The engine's weapon space is x=right, y=forward, z=up, so the
  export maps (x, y, z) -> (-y, x, z). That is a rotation, not a mirror, so the
  triangle winding survives and the pipeline's COUNTER_CLOCKWISE culling holds.

  Attachment. The arms rig carries a hand_item_r bone. Comparing the rifle's
  armature transform against that bone in the shipped scene shows the gun sits
  at bone_matrix @ rotate_x(-90). That is what puts the pistol and the knife --
  neither of which comes posed with the arms -- into the right hand.
"""

import math
import struct
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gun_palette

ROOT = Path(bpy.path.abspath("//")) if bpy.data.filepath else Path.cwd()
ASSETS = ROOT / "assets"
OUT = ROOT / "models"

MAGIC = b"DMSH"
VERSION = 1
NAME_LEN = 32

# Tile origins inside an atlased texture set, in UV space with v running down
# the image. Two sets are atlased and both are 2x2, which is why one scale
# covers them: RetroWeapons (rifle, pistol, arms, projectiles) and NadeMolotov,
# whose bottle, wick and liquid each ship their own maps and would otherwise
# cost three layers for one bottle. Must match TILES and EXPLOSIVE_SETS in
# build_model_textures.py.
ATLAS_TILES = {
    "rifle": (0.0, 0.0),
    "pistol": (0.5, 0.0),
    "arms": (0.0, 0.5),
    "projectiles": (0.5, 0.5),
    "molotov_bottle": (0.0, 0.0),
    "molotov_fabric": (0.5, 0.0),
    "molotov_liquid": (0.0, 0.5),
}
ATLAS_SCALE = 0.5

# Last frame of the pistol scene's draw animation, where the hand has arrived at
# the held position and stays. Everything in that scene starts from a lowered
# weapon, so frame 1 is unusable as a pose.
PISTOL_HELD_FRAME = 20

# Rig widgets and the studio backdrop. They have no material, but so do a few
# real meshes, so they are named out explicitly.
SKIP_PREFIXES = ("Ctrl_Mesh", "Cube", "Camera")

# Magazine variants that ship alongside the rigged one -- exporting all of them
# would put three magazines inside the pistol.
SKIP_EXACT = (
    "Pistol_01_Magazine_Full_Mesh",
    "Pistol_01_Magazine_Mesh_Separated",
    "Pistol_01_Magazine_OneBullet_Mesh",
)

RETRO_MATERIALS = {
    # The arms mesh ships with Blender's default material name
    "Material": ("retro_arms", "arms"),
    "Arms_MI": ("retro_arms", "arms"),
    # Skin and gunmetal share the atlas but not their shading: two materials on
    # one texture layer is what keeps the arms from turning metallic.
    "Rifle_01_MI": ("retro_guns", "rifle"),
    "Pistol_01_MI": ("retro_guns", "pistol"),
    "Projectiles_MI": ("retro_guns", "projectiles"),
}

# The two arms scenes every gun viewmodel starts from. The rifle scene's own
# gun is a single oddly named mesh (ChargeHandle_Mesh is the whole rifle);
# excluding it leaves two-handed arms ready for an attached gun. The pistol
# scene's gun is a linked Pistol_Mesh, which only resolves because
# extract_models.sh puts Pistol_01.blend in the same directory.
#
# Unlike the rifle scene, frame 1 in the pistol scene is the weapon lowered:
# every action starts from it. The held pose is where the draw ends, so that is
# the frame to bake.
RIFLE_ARMS = {
    "blend": "retro/blend/FP_Arms_Rifle_01_Anims.blend",
    "actions": {"Arms_Armature": "Arms_BasePose"},
    "exclude": ("ChargeHandle_Mesh",),
}
PISTOL_ARMS = {
    "blend": "retro/blend/FP_Arms_Pistol_01_Anims.blend",
    "actions": {"Arms_Armature": "Arms_Draw"},
    "frame": PISTOL_HELD_FRAME,
    "exclude": ("Pistol_Mesh",),
}


def gun(name, arms, stem, length, tweak_euler=(0.0, 0.0, 0.0), tweak_offset=(0.0, 0.0, 0.0)):
    """A viewmodel spec: the arms scene holding one gun-pack FBX, colours from
    the shared palette swatches. `length` is the real-world size the import is
    normalised to, metres; the tweaks turn the import into the grip."""
    return {
        "name": name,
        **arms,
        "attach": {
            "fbx": f"guns/fbx/{stem}.fbx",
            "length": length,
            "tweak_euler": tweak_euler,
            "tweak_offset": tweak_offset,
        },
    }


# Offsets are in the hand frame, which sits axis-aligned with the world here:
# x forward, y left, z up, scene units (cm). The rifle hand hangs 25 cm under
# the eye line, so every long gun gets lifted toward it; the short ones also
# move forward or the camera looks straight down onto their top rail.
VIEWMODELS = [
    # Some pack models are saved tilted (the preview shows them at jaunty
    # angles); the Y euler levels the barrel again. Positive Y pitches the
    # muzzle down. Stocks reach behind the grip, so the long guns move forward
    # or the stock ends up inside the camera.
    gun("view_ak", RIFLE_ARMS, "AssaultRifle_1", 0.88,
        tweak_euler=(0.0, 6.0, 0.0), tweak_offset=(12.0, 0.0, 2.0)),
    gun("view_m4", RIFLE_ARMS, "AssaultRifle2_1", 0.84,
        tweak_euler=(0.0, 5.0, 0.0), tweak_offset=(20.0, 0.0, 4.0)),
    gun("view_awp", RIFLE_ARMS, "SniperRifle_1", 1.23, tweak_offset=(0.0, 0.0, 10.0)),
    gun("view_mac10", RIFLE_ARMS, "SubmachineGun_2", 0.50, tweak_offset=(12.0, 0.0, 8.0)),
    gun("view_mp9", RIFLE_ARMS, "SubmachineGun_4", 0.35,
        tweak_euler=(0.0, 14.0, 0.0), tweak_offset=(14.0, 0.0, 8.0)),
    gun("view_nova", RIFLE_ARMS, "Shotgun_1", 1.05,
        tweak_euler=(0.0, -12.0, 0.0), tweak_offset=(10.0, 0.0, 8.0)),
    gun("view_glock", PISTOL_ARMS, "Pistol_4", 0.19),
    gun("view_usp", PISTOL_ARMS, "Pistol_5", 0.24),
    gun("view_deagle", PISTOL_ARMS, "Pistol_6", 0.27),
    # The bayonet points down +X with the edge vertical; a slight tilt keeps
    # the blade readable instead of edge-on.
    gun("view_knife", PISTOL_ARMS, "Bayonet", 0.30,
        tweak_euler=(0.0, -30.0, 35.0), tweak_offset=(6.0, 0.0, 4.0)),
]


class AllTo:
    """A material map that answers the same thing whatever it is asked.

    The explosives pack names its materials Mat, Mat.1, Luger -- names that
    collide between models and describe nothing -- but each of its models has
    exactly one texture set, so the name never has to be consulted. Meshes that
    carry no material slots at all (four of them do) also land here, which the
    dict form could not do."""

    def __init__(self, target, tile=None):
        self.answer = (target, tile)

    def get(self, name, default=None):
        return self.answer


def held(name, stem, length, materials, tweak_euler=(0.0, 0.0, 0.0),
         tweak_offset=(0.0, 0.0, 0.0)):
    """A viewmodel for something that is not a gun: a grenade, the bomb.

    Same arms scene and the same hand attachment as gun(), and the same pairing
    with build_world_weapon, so each of these also yields the world_* mesh that
    the thrown version and the dropped bomb are drawn with. What differs is the
    texturing: these meshes bring their own UVs, so they point at a texture set
    of their own instead of at a palette swatch.

    The arms are posed but not exported (`no_arms`). The retro arms belong to a
    pistol grip and read as a fist wrapped around nothing once the thing in it
    is a canister; a dedicated pair is a later piece of work, and until then a
    floating grenade beats a wrong grip. The pose still runs, because it is what
    hand_matrix() measures the placement from -- the object lands in exactly the
    spot it would have been held in."""
    return {
        "name": name,
        **PISTOL_ARMS,
        "attach": {
            "fbx": f"explosives/{stem}.fbx",
            "length": length,
            "tweak_euler": tweak_euler,
            "tweak_offset": tweak_offset,
        },
        "materials": materials,
        "no_arms": True,
    }


# Everything the hands can hold that is not a gun. Lengths are the real-world
# size of the object, metres -- the pack models arrive at roughly that scale
# already, so these are close to their own bounds rather than a correction.
# The offsets push the thing out of the fist: the pistol pose closes the hand
# around a grip, and an object centred on that grip is swallowed by the fingers
# the way a 15 cm canister has no business being. Forward and a little up is
# where a held grenade reads, and it is the same correction the knife needed.
HELD_ITEMS = [
    held("view_he", "FragGrenadeModel", 0.11, AllTo("nade_frag"),
         tweak_offset=(15.0, 0.0, 10.0)),
    held("view_flash", "Flashbang", 0.13, AllTo("nade_flash"),
         tweak_offset=(15.0, 0.0, 10.0)),
    held("view_smoke", "Smoke_Grenade", 0.15, AllTo("nade_smoke"),
         tweak_offset=(15.0, 0.0, 10.0)),
    # The bottle and the satchel are wide enough to fill the frame at their real
    # size, so both are cut down and lifted least: what matters is recognising
    # them at a glance, not measuring them.
    held("view_molotov", "Molotov_Cocktail", 0.20, {
        "Bottle": ("nade_molotov", "molotov_bottle"),
        "Fabric": ("nade_molotov", "molotov_fabric"),
        "Liquid": ("nade_molotov", "molotov_liquid"),
    }, tweak_offset=(15.0, 0.0, 4.0)),
    held("view_c4", "C4", 0.17, AllTo("bomb_c4"),
         tweak_offset=(16.0, 0.0, 1.0)),
]

# The rest of the explosives pack: on disk as geometry, plain grey until one of
# them is wanted. Promoting one is a texture set in build_model_textures.py, a
# material row in src/material.odin, a name in mesh_material_index, and a
# HELD_ITEMS entry (or a prop placement) -- the five above are the worked
# example. Not converted through HELD_ITEMS because none of them belongs in a
# hand: they are mines, bombs and a second set of guns.
PACK_MODELS = [
    "AK47", "AT_MINE", "Claymore", "FlareGun", "Grease_Gun", "Luger",
    "M24Grenade", "M4A1", "Makarov", "Nuclear_Bomb", "Pipe_Bomb", "Shotgun",
    "Sniper", "Suomi_KP",
]


# --------------------------------------------------------------------- scene


def open_blend(rel):
    path = ASSETS / rel
    if not path.exists():
        sys.exit(f"missing {path} -- run tools/extract_models.sh")
    bpy.ops.wm.open_mainfile(filepath=str(path))


def apply_actions(actions, frame=1):
    for obj_name, action_name in actions.items():
        obj = bpy.data.objects.get(obj_name)
        if obj is None or obj.animation_data is None:
            print(f"    warn: no armature {obj_name}")
            continue
        action = bpy.data.actions.get(action_name)
        if action is None:
            print(f"    warn: no action {action_name}")
            continue
        obj.animation_data.action = action
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()


def hand_matrix():
    """Where a held item sits, in the arms' world space."""
    arms = bpy.data.objects.get("Arms_Armature")
    if arms is None:
        sys.exit("no Arms_Armature in this scene")
    bone = arms.pose.bones["hand_item_r"]
    return arms.matrix_world @ bone.matrix @ Matrix.Rotation(math.radians(-90), 4, "X")


def attach_weapon(spec):
    """Imports a weapon the scene does not already hold and parks it in the
    right hand. Only the knife needs this; the two guns come posed.

    Returns the objects it added, which is what lets the world variant export
    the gun on its own."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(ASSETS / spec["fbx"]))
    added = [o for o in bpy.data.objects if o not in before]
    # Every piece the import brought that is not already hanging off another
    # one. The old version parented them all to added[0] and moved that -- which
    # works for a one-mesh file and scatters a multi-part one, because the list
    # order is arbitrary and "the root" ended up being the smoke grenade's pin.
    # Applying the same matrix to each of them needs no parenting at all.
    tops = [o for o in added if o.parent is None or o.parent not in added]

    scale = 1.0
    if "length" in spec:
        unit = bpy.context.scene.unit_settings.scale_length
        # Every mesh the import brought, not just the root's own box. The gun
        # pack is one mesh per file, so this measures the same thing it always
        # did there; the explosives pack is not, and its root is sometimes an
        # empty whose box has no size at all.
        corners = []
        for obj in added:
            if obj.type != "MESH":
                continue
            corners += [obj.matrix_world @ Vector(c) for c in obj.bound_box]
        if not corners:
            sys.exit(f"{spec['fbx']}: the import brought no mesh to measure")
        longest = max(
            max(c[i] for c in corners) - min(c[i] for c in corners) for i in range(3)
        )
        scale = (spec["length"] / unit) / longest

    m = hand_matrix()
    if "tweak_euler" in spec:
        rx, ry, rz = (math.radians(a) for a in spec["tweak_euler"])
        m = m @ (Matrix.Rotation(rx, 4, "X") @ Matrix.Rotation(ry, 4, "Y")
                 @ Matrix.Rotation(rz, 4, "Z"))
    if "tweak_offset" in spec:
        m = m @ Matrix.Translation(Vector(spec["tweak_offset"]))
    if scale != 1.0:
        m = m @ Matrix.Scale(scale, 4)

    # Multiplied onto whatever the import left on the object rather than
    # replacing it: an FBX arrives carrying its own unit conversion in the
    # object scale, and dropping that is how a knife ends up 19 metres long.
    for obj in tops:
        obj.matrix_world = m @ obj.matrix_world
    bpy.context.view_layer.update()
    return added


def exportable_meshes(exclude=()):
    out = []
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.name in SKIP_EXACT or obj.name in exclude:
            continue
        if any(obj.name.startswith(p) for p in SKIP_PREFIXES):
            continue
        if len(obj.data.polygons) == 0 or not obj.data.materials:
            continue
        out.append(obj)
    return out


# --------------------------------------------------------------- geometry


class Builder:
    """Collects loops into the engine's vertex layout, welding duplicates."""

    def __init__(self, axes, unit_scale):
        self.axes = axes
        self.unit_scale = unit_scale
        self.lookup = {}
        self.vertices = []
        self.indices = []
        self.materials = []

    def material_slot(self, name):
        if name not in self.materials:
            self.materials.append(name)
        return self.materials.index(name)

    def convert(self, v):
        """Blender world space to engine space."""
        x, y, z = v.x * self.unit_scale, v.y * self.unit_scale, v.z * self.unit_scale
        return (-y, x, z) if self.axes == "viewmodel" else (x, y, z)

    def convert_dir(self, v):
        return (-v.y, v.x, v.z) if self.axes == "viewmodel" else (v.x, v.y, v.z)

    def add(self, pos, normal, tangent, sign, uv, slot):
        key = (pos, normal, tangent, sign, uv, slot)
        index = self.lookup.get(key)
        if index is None:
            index = len(self.vertices)
            self.lookup[key] = index
            self.vertices.append(key)
        self.indices.append(index)

    def add_object(self, obj, material_map, flat_tangents=False):
        # Tangent space needs tris or quads, and several of these meshes have
        # n-gons. A temporary modifier at the end of the stack triangulates
        # after the armature has already posed the mesh.
        #
        # flat_tangents is for palette-mapped meshes whose UVs are constant per
        # face: calc_tangents has no UV gradient to work with there, so a
        # synthetic tangent stands in while the real UVs are kept.
        triangulate = obj.modifiers.new("export_triangulate", "TRIANGULATE")
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        try:
            mesh.calc_loop_triangles()
            # The gun-pack meshes carry no UVs at all; their materials map to
            # palette swatches instead, with a constant UV per loop. Tangents
            # can only be computed where UVs exist.
            has_uv = mesh.uv_layers.active is not None
            if has_uv and not flat_tangents:
                mesh.calc_tangents()

            world = obj.matrix_world
            # Non-uniform scale would skew normals; these rigs have none, but the
            # inverse transpose costs nothing and removes the assumption.
            normal_matrix = world.to_3x3().inverted_safe().transposed()
            uvs = mesh.uv_layers.active.data if has_uv else None

            slots = []
            for material in mesh.materials:
                # Appending from a second file suffixes colliding names, so
                # Pistol_01_MI arrives as Pistol_01_MI.001
                name = material.name.split(".00")[0] if material else ""
                target, tile = material_map.get(name, (None, None))
                if target is None:
                    if name:
                        print(f"    warn: material {name!r} unmapped, skipped")
                    slots.append(None)
                    continue
                slots.append((self.material_slot(target), tile))

            if not slots:
                # No material slots at all -- four of the explosives pack's
                # models ship that way, and every triangle on them reports
                # material_index 0. One synthetic slot covers the mesh; a map
                # that answers per name has nothing to answer here, so this only
                # ever resolves through an AllTo.
                target, tile = material_map.get("", (None, None))
                slots.append(None if target is None else (self.material_slot(target), tile))

            for tri in mesh.loop_triangles:
                slot = slots[tri.material_index] if tri.material_index < len(slots) else None
                if slot is None:
                    continue
                index, tile = slot
                is_swatch = isinstance(tile, tuple)
                if not is_swatch and not has_uv:
                    print(f"    warn: {obj.name} has no UVs for {tile!r}, face skipped")
                    continue
                for loop_index in tri.loops:
                    loop = mesh.loops[loop_index]
                    pos = self.convert(world @ mesh.vertices[loop.vertex_index].co)
                    normal = Vector(self.convert_dir(normal_matrix @ loop.normal)).normalized()

                    if is_swatch:
                        # Constant UV at the swatch centre; the palette normal
                        # map is flat, so the tangent only has to be valid.
                        uv = tile[1]
                        tangent = fallback_tangent(normal)
                        sign = 1.0
                    else:
                        if flat_tangents:
                            tangent = fallback_tangent(normal)
                            sign = 1.0
                        else:
                            tangent = Vector(
                                self.convert_dir(world.to_3x3() @ loop.tangent)
                            ).normalized()
                            sign = loop.bitangent_sign
                        u, v = uvs[loop_index].uv
                        # Blender's v runs up the image, the engine's runs down it
                        uv = (u, 1.0 - v)
                        if tile is not None:
                            ox, oy = ATLAS_TILES[tile]
                            uv = (uv[0] * ATLAS_SCALE + ox, uv[1] * ATLAS_SCALE + oy)

                    self.add(
                        pos,
                        (normal.x, normal.y, normal.z),
                        (tangent.x, tangent.y, tangent.z),
                        sign,
                        uv,
                        index,
                    )
        finally:
            evaluated.to_mesh_clear()
            obj.modifiers.remove(triangulate)

    def bounds(self):
        if not self.vertices:
            return (0, 0, 0), (0, 0, 0)
        xs = [v[0] for v in self.vertices]
        return (
            tuple(min(p[i] for p in xs) for i in range(3)),
            tuple(max(p[i] for p in xs) for i in range(3)),
        )

    def translate(self, offset):
        self.vertices = [
            ((v[0][0] + offset[0], v[0][1] + offset[1], v[0][2] + offset[2]),) + v[1:]
            for v in self.vertices
        ]

    def write(self, path):
        mn, mx = self.bounds()
        blob = bytearray()
        blob += MAGIC
        blob += struct.pack(
            "<IIII", VERSION, len(self.vertices), len(self.indices), len(self.materials)
        )
        blob += struct.pack("<3f", *mn)
        blob += struct.pack("<3f", *mx)
        for name in self.materials:
            raw = name.encode("ascii")
            if len(raw) >= NAME_LEN:
                sys.exit(f"material name {name!r} does not fit in {NAME_LEN} bytes")
            blob += raw + b"\0" * (NAME_LEN - len(raw))
        for pos, normal, tangent, sign, uv, slot in self.vertices:
            blob += struct.pack(
                "<3f3f4f2fI",
                *pos,
                *normal,
                tangent[0],
                tangent[1],
                tangent[2],
                sign,
                uv[0],
                uv[1],
                slot,
            )
        blob += struct.pack(f"<{len(self.indices)}I", *self.indices)

        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(blob)

        size = tuple(round(mx[i] - mn[i], 3) for i in range(3))
        print(
            f"  {path.name:24} {len(self.vertices):6} verts {len(self.indices)//3:6} tris "
            f"size={size} m  materials={self.materials}"
        )


# ------------------------------------------------------------------ collada

# This build of Blender ships without the Collada importer, and the prop pack is
# Collada only. The files are all one Blender 2.76 export away from each other --
# Z-up, metres, one <polylist> per material, positions/normals/UVs indexed
# separately -- so reading them directly is shorter than any way of getting them
# through Blender would be.


def collada_sources(mesh, ns):
    """id -> (floats, stride) for every <source> in a <mesh>."""
    out = {}
    for source in mesh.findall(f"{ns}source"):
        array = source.find(f"{ns}float_array")
        accessor = source.find(f"{ns}technique_common/{ns}accessor")
        if array is None or accessor is None:
            continue
        out["#" + source.get("id")] = (
            [float(v) for v in array.text.split()],
            int(accessor.get("stride", "1")),
        )
    # <vertices> is an alias layer that points at the position source
    for vertices in mesh.findall(f"{ns}vertices"):
        for inp in vertices.findall(f"{ns}input"):
            if inp.get("semantic") == "POSITION":
                out["#" + vertices.get("id")] = out[inp.get("source")]
    return out


def fallback_tangent(normal):
    """A unit tangent for UV-less swatch geometry: any stable direction not
    parallel to the normal, Gram-Schmidt orthogonalised."""
    axis = Vector((1.0, 0.0, 0.0)) if abs(normal.x) < 0.9 else Vector((0.0, 0.0, 1.0))
    t = axis - normal * normal.dot(axis)
    return t.normalized() if t.length > 1e-8 else Vector((0.0, 1.0, 0.0))


def triangle_tangent(positions, uvs):
    """glTF-convention tangent for one triangle, or None when the UVs degenerate."""
    e1 = [positions[1][i] - positions[0][i] for i in range(3)]
    e2 = [positions[2][i] - positions[0][i] for i in range(3)]
    du1, dv1 = uvs[1][0] - uvs[0][0], uvs[1][1] - uvs[0][1]
    du2, dv2 = uvs[2][0] - uvs[0][0], uvs[2][1] - uvs[0][1]
    det = du1 * dv2 - du2 * dv1
    if abs(det) < 1e-12:
        return None
    r = 1.0 / det
    return Vector([(e1[i] * dv2 - e2[i] * dv1) * r for i in range(3)])


def add_collada(builder, path):
    import xml.etree.ElementTree as ET

    root = ET.parse(path).getroot()
    ns = "{http://www.collada.org/2005/11/COLLADASchema}"

    # Every geometry is instanced by exactly one node in these files, and the
    # node carries the transform that puts the Y-up export back on its feet.
    transforms = {}
    for node in root.iter(f"{ns}node"):
        instance = node.find(f"{ns}instance_geometry")
        if instance is None:
            continue
        matrix = node.find(f"{ns}matrix")
        values = [float(v) for v in matrix.text.split()] if matrix is not None else None
        transforms[instance.get("url")] = (
            Matrix([values[0:4], values[4:8], values[8:12], values[12:16]])
            if values
            else Matrix.Identity(4)
        )

    slot = builder.material_slot("prop_palette")

    for geometry in root.iter(f"{ns}geometry"):
        mesh = geometry.find(f"{ns}mesh")
        if mesh is None:
            continue
        world = transforms.get("#" + geometry.get("id"), Matrix.Identity(4))
        normal_matrix = world.to_3x3().inverted_safe().transposed()
        sources = collada_sources(mesh, ns)

        for polylist in mesh.findall(f"{ns}polylist"):
            inputs = {}
            stride = 0
            for inp in polylist.findall(f"{ns}input"):
                offset = int(inp.get("offset"))
                inputs[inp.get("semantic")] = (offset, sources[inp.get("source")])
                stride = max(stride, offset + 1)

            counts = [int(v) for v in polylist.find(f"{ns}vcount").text.split()]
            flat = [int(v) for v in polylist.find(f"{ns}p").text.split()]

            def corner(entry, semantic, width):
                offset, (data, data_stride) = inputs[semantic]
                base = entry[offset] * data_stride
                return data[base:base + width]

            cursor = 0
            for count in counts:
                corners = [flat[(cursor + i) * stride:(cursor + i + 1) * stride]
                           for i in range(count)]
                cursor += count

                # Fan triangulation. These props are convex faces on boxes and
                # cylinder caps, where a fan is exact.
                for i in range(1, count - 1):
                    tri = [corners[0], corners[i], corners[i + 1]]
                    positions, normals, uvs = [], [], []
                    for entry in tri:
                        p = world @ Vector(corner(entry, "VERTEX", 3))
                        n = (normal_matrix @ Vector(corner(entry, "NORMAL", 3))).normalized()
                        u, v = corner(entry, "TEXCOORD", 2)
                        positions.append(builder.convert(p))
                        normals.append(builder.convert_dir(n))
                        uvs.append((u, 1.0 - v))

                    tangent = triangle_tangent(positions, uvs)
                    for j in range(3):
                        n = Vector(normals[j])
                        t = tangent if tangent is not None else Vector((1.0, 0.0, 0.0))
                        # Gram-Schmidt, so the tangent stays perpendicular to
                        # the shading normal the way the shader assumes
                        t = (t - n * n.dot(t))
                        t = t.normalized() if t.length > 1e-8 else Vector((1.0, 0.0, 0.0))
                        builder.add(
                            positions[j],
                            (n.x, n.y, n.z),
                            (t.x, t.y, t.z),
                            1.0,
                            uvs[j],
                            slot,
                        )


# ------------------------------------------------------------------- models


def gun_swatch_map():
    """Gun-pack material name -> (engine material, swatch UV)."""
    out = {}
    for index, (mat_name, _) in enumerate(gun_palette.swatches(ASSETS)):
        out[mat_name] = (
            gun_palette.engine_material(mat_name),
            ("swatch", gun_palette.swatch_uv(index)),
        )
    return out


def plain_map():
    """Everything onto the palette's reserved grey cell -- for models that are
    on disk without a texture set of their own."""
    return AllTo("gun_matte", ("swatch", gun_palette.swatch_uv(gun_palette.PLAIN_INDEX)))


def build_viewmodel(spec):
    print(f"{spec['name']}:")
    open_blend(spec["blend"])
    apply_actions(spec.get("actions", {}), spec.get("frame", 1))

    # The gun-pack material names (Black, Metal, ...) never collide with the
    # retro names, so the swatch map simply rides along in every scene.
    scene_map = dict(RETRO_MATERIALS)
    scene_map.update(gun_swatch_map())

    # A held item brings its own texture set; the arms holding it must not. Two
    # maps rather than one merged one, because the pack's material names are
    # generic enough (Mat, Mat.1) that merging would be a collision waiting to
    # re-texture somebody's forearm.
    attach_map = spec.get("materials", scene_map)

    attached = set()
    if "attach" in spec:
        attached = set(attach_weapon(spec["attach"]))

    builder = Builder("viewmodel", bpy.context.scene.unit_settings.scale_length)
    for obj in exportable_meshes(spec.get("exclude", ())):
        # no_arms keeps the posed scene but exports only what it is holding.
        if spec.get("no_arms") and obj not in attached:
            continue
        before = len(builder.vertices)
        builder.add_object(obj, attach_map if obj in attached else scene_map)
        # Per object, in engine view space: this is where a weapon that ends up
        # inside a fist or behind the camera shows itself.
        added = [v[0] for v in builder.vertices[before:]]
        if added:
            mn = tuple(round(min(p[i] for p in added), 3) for i in range(3))
            mx = tuple(round(max(p[i] for p in added), 3) for i in range(3))
            print(f"    {obj.name:24} {mn} .. {mx}")
    builder.write(OUT / f"{spec['name']}.mesh")


def build_world_weapon(spec):
    """The same gun again, without the arms and posed about the hand rather than
    about the eye -- what another player is seen carrying.

    The viewmodel meshes cannot serve: they have the first-person arms welded
    into them and their origin is the camera. This one's origin is the grip, so
    the runtime can hang it off the character's hand joint with nothing but that
    joint's matrix."""
    if "attach" not in spec:
        return
    print(f"{spec['name']} (world):")
    open_blend(spec["blend"])
    apply_actions(spec.get("actions", {}), spec.get("frame", 1))

    material_map = spec.get("materials", gun_swatch_map())

    added = attach_weapon(spec["attach"])

    # Re-anchor onto the hand. Moving the objects rather than the exported
    # vertices keeps every normal and tangent consistent with the positions,
    # and leaves the Builder's one axis convention doing the rest.
    into_hand = hand_matrix().inverted()
    for obj in added:
        if obj.parent is None:
            obj.matrix_world = into_hand @ obj.matrix_world
    bpy.context.view_layer.update()

    builder = Builder("viewmodel", bpy.context.scene.unit_settings.scale_length)
    meshes = [o for o in added if o.type == "MESH" and o.data.materials and o.data.polygons]
    if not meshes:
        sys.exit(f"{spec['name']}: the attachment brought no mesh to export")
    for obj in meshes:
        builder.add_object(obj, material_map)
    builder.write(OUT / f"world_{spec['name'][len('view_'):]}.mesh")


def build_props():
    sources = sorted((ASSETS / "props" / "models").glob("*.dae"))
    if not sources:
        print("no props found")
        return
    print(f"props ({len(sources)}):")
    for path in sources:
        builder = Builder("world", 1.0)
        add_collada(builder, path)

        # Props are placed by where they stand, so the origin goes to the middle
        # of the footprint at floor level.
        mn, mx = builder.bounds()
        builder.translate((-(mn[0] + mx[0]) * 0.5, -(mn[1] + mx[1]) * 0.5, -mn[2]))

        name = "prop_" + path.stem.lower().replace("-", "_")
        builder.write(OUT / f"{name}.mesh")


# The modular prototyping pieces worth having as map decoration. The pack also
# ships primitives and pickup trinkets (spheres, coins, keys); those stay out.
MODULAR_PIECES = [
    "fence",
    "fence2",
    "fence3",
    "fence wood",
    "railing",
    "railing edge",
    "pillar",
    "pillar1",
    "pillar2",
    "stairs",
    "stairs corner",
    "ramp",
    "wall door",
    "door",
    "window",
    "ladder",
]


def build_modular():
    src = ASSETS / "modular" / "pieces"
    if not src.exists():
        print("no modular pieces found")
        return
    print(f"modular ({len(MODULAR_PIECES)}):")
    # One material across the whole pack, UV-mapped onto the 8x8 palette. The
    # UVs are constant per face, hence the flat tangents.
    material_map = {"Material": ("mod_palette", None)}

    for stem in MODULAR_PIECES:
        path = src / f"{stem}.fbx"
        if not path.exists():
            sys.exit(f"missing {path} -- run tools/extract_models.sh")

        # A fresh empty scene per piece: the FBX files are tiny and this keeps
        # one import from ever seeing another's objects.
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.fbx(filepath=str(path))

        # The pieces arrive Z-up in metres; matrix_world carries whatever the
        # importer decided, so "world" axes and unit 1.0 are already right.
        builder = Builder("world", 1.0)
        for obj in exportable_meshes():
            builder.add_object(obj, material_map, flat_tangents=True)

        # Same convention as the props: the pieces sit scattered around their
        # authoring scene, so the origin goes to the footprint centre at floor
        # level, which is what fit_transform placement assumes.
        mn, mx = builder.bounds()
        builder.translate((-(mn[0] + mx[0]) * 0.5, -(mn[1] + mx[1]) * 0.5, -mn[2]))

        name = "mod_" + stem.replace(" ", "_")
        builder.write(OUT / f"{name}.mesh")


def build_pack_models():
    """The explosives pack's leftovers, as plain geometry.

    Kept out of the hand-and-arms path on purpose: these are mines, satchels
    and a second set of rifles, none of which anything holds yet. They convert
    so the pack is on disk in the engine's own format rather than as FBX nobody
    has looked at, and they wear the palette's grey until one of them earns a
    texture set."""
    src = ASSETS / "explosives"
    if not src.exists():
        print("no explosives pack found")
        return
    print(f"explosives pack ({len(PACK_MODELS)}):")
    material_map = plain_map()

    for stem in PACK_MODELS:
        path = src / f"{stem}.fbx"
        if not path.exists():
            sys.exit(f"missing {path} -- run tools/extract_models.sh")

        # A fresh empty scene per model, like build_modular: these carry generic
        # material names, and one import seeing another's objects is how a
        # Mat.001 ends up meaning two different things.
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.fbx(filepath=str(path))

        builder = Builder("world", 1.0)
        for obj in bpy.context.scene.objects:
            if obj.type != "MESH" or not obj.data.polygons:
                continue
            builder.add_object(obj, material_map, flat_tangents=True)
        if not builder.vertices:
            print(f"    warn: {stem} exported nothing")
            continue

        # Same convention as the props: origin at the footprint centre, floor
        # level, so a placement only has to say where it stands.
        mn, mx = builder.bounds()
        builder.translate((-(mn[0] + mx[0]) * 0.5, -(mn[1] + mx[1]) * 0.5, -mn[2]))
        builder.write(OUT / f"pack_{stem.lower()}.mesh")


def main():
    if not ASSETS.exists():
        sys.exit("assets/ missing -- run tools/extract_models.sh first")
    OUT.mkdir(parents=True, exist_ok=True)

    # `blender -b -P convert_models.py -- modular` rebuilds only the modular
    # pieces, `-- held` only the grenades and the bomb (the loop their hand
    # poses are tuned in), `-- pack` only the untextured leftovers. The full run
    # re-bakes everything and takes minutes.
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    only = set(args)
    if not only or "held" in only:
        for spec in HELD_ITEMS:
            build_viewmodel(spec)
            build_world_weapon(spec)
    if not only:
        for spec in VIEWMODELS:
            build_viewmodel(spec)
            build_world_weapon(spec)
        build_props()
    if not only or "pack" in only:
        build_pack_models()
    if not only or "modular" in only:
        build_modular()
    print(f"models written to {OUT}")


main()
