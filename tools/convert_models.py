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

ROOT = Path(bpy.path.abspath("//")) if bpy.data.filepath else Path.cwd()
ASSETS = ROOT / "assets"
OUT = ROOT / "models"

MAGIC = b"DMSH"
VERSION = 1
NAME_LEN = 32

# Tile origins in the RetroWeapons atlas, in UV space with v running down the
# image. Must match TILES in build_model_textures.py.
ATLAS_TILES = {
    "rifle": (0.0, 0.0),
    "pistol": (0.5, 0.0),
    "arms": (0.0, 0.5),
    "projectiles": (0.5, 0.5),
}
ATLAS_SCALE = 0.5

# The throwing knife measures 23 cm tip to pommel in its own file; anything
# imported gets normalised to a real-world length rather than trusted.
KNIFE_LENGTH = 0.23

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
    "ThrowingKnifeMaterial": ("throwing_knife", None),
}

VIEWMODELS = [
    {
        "name": "view_rifle",
        "blend": "retro/blend/FP_Arms_Rifle_01_Anims.blend",
        "actions": {"Arms_Armature": "Arms_BasePose", "Rifle_01_Armature": "Rifle_BasePose"},
    },
    {
        "name": "view_pistol",
        # The gun in this scene is a linked Pistol_Mesh, which only resolves
        # because extract_models.sh puts Pistol_01.blend in the same directory --
        # without it the scene loads as arms holding nothing.
        "blend": "retro/blend/FP_Arms_Pistol_01_Anims.blend",
        # Unlike the rifle scene, frame 1 here is the weapon lowered: every
        # action starts from it. The held pose is where the draw ends, so that
        # is the frame to bake.
        "actions": {"Arms_Armature": "Arms_Draw"},
        "frame": PISTOL_HELD_FRAME,
    },
    {
        "name": "view_knife",
        # No knife arms pose exists; the pistol pose is the closest thing to a
        # fist the pack has. The tweak below turns the blade out of the palm.
        "blend": "retro/blend/FP_Arms_Pistol_01_Anims.blend",
        "actions": {"Arms_Armature": "Arms_Draw"},
        "frame": PISTOL_HELD_FRAME,
        # the hand is holding a knife now, so the scene's pistol has to go
        "exclude": ("Pistol_Mesh",),
        "attach": {
            "fbx": "knife/throwing_knife.fbx",
            # Given as the length it should end up, not as a factor: the FBX
            # importer's unit handling depends on the scene it lands in, and a
            # measured target survives that.
            "length": KNIFE_LENGTH,
            # The blade lies flat in XY and points down +X. Standing it fully
            # upright turns it edge-on to the camera -- three millimetres of
            # steel, invisible -- so it is tilted instead, and turned across the
            # body the way a knife is actually carried.
            "tweak_euler": (0.0, -40.0, 75.0),
            "tweak_offset": (4.0, 0.0, 2.0),
        },
    },
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
    right hand. Only the knife needs this; the two guns come posed."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.fbx(filepath=str(ASSETS / spec["fbx"]))
    added = [o for o in bpy.data.objects if o not in before]
    root = added[0]
    for obj in added[1:]:
        if obj.parent is None:
            obj.parent = root

    scale = 1.0
    if "length" in spec:
        unit = bpy.context.scene.unit_settings.scale_length
        corners = [root.matrix_world @ Vector(c) for c in root.bound_box]
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
    root.matrix_world = m @ root.matrix_world
    bpy.context.view_layer.update()


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

    def add_object(self, obj, material_map):
        # Tangent space needs tris or quads, and several of these meshes have
        # n-gons. A temporary modifier at the end of the stack triangulates
        # after the armature has already posed the mesh.
        triangulate = obj.modifiers.new("export_triangulate", "TRIANGULATE")
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        try:
            mesh.calc_loop_triangles()
            if not mesh.uv_layers.active:
                print(f"    warn: {obj.name} has no UVs, skipped")
                return
            mesh.calc_tangents()

            world = obj.matrix_world
            # Non-uniform scale would skew normals; these rigs have none, but the
            # inverse transpose costs nothing and removes the assumption.
            normal_matrix = world.to_3x3().inverted_safe().transposed()
            uvs = mesh.uv_layers.active.data

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

            for tri in mesh.loop_triangles:
                slot = slots[tri.material_index] if tri.material_index < len(slots) else None
                if slot is None:
                    continue
                index, tile = slot
                for loop_index in tri.loops:
                    loop = mesh.loops[loop_index]
                    pos = self.convert(world @ mesh.vertices[loop.vertex_index].co)
                    normal = Vector(self.convert_dir(normal_matrix @ loop.normal)).normalized()
                    tangent = Vector(self.convert_dir(world.to_3x3() @ loop.tangent)).normalized()

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
                        loop.bitangent_sign,
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


def build_viewmodel(spec):
    print(f"{spec['name']}:")
    open_blend(spec["blend"])
    apply_actions(spec.get("actions", {}), spec.get("frame", 1))
    if "attach" in spec:
        attach_weapon(spec["attach"])

    builder = Builder("viewmodel", bpy.context.scene.unit_settings.scale_length)
    for obj in exportable_meshes(spec.get("exclude", ())):
        before = len(builder.vertices)
        builder.add_object(obj, RETRO_MATERIALS)
        # Per object, in engine view space: this is where a weapon that ends up
        # inside a fist or behind the camera shows itself.
        added = [v[0] for v in builder.vertices[before:]]
        if added:
            mn = tuple(round(min(p[i] for p in added), 3) for i in range(3))
            mx = tuple(round(max(p[i] for p in added), 3) for i in range(3))
            print(f"    {obj.name:24} {mn} .. {mx}")
    builder.write(OUT / f"{spec['name']}.mesh")


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


def main():
    if not ASSETS.exists():
        sys.exit("assets/ missing -- run tools/extract_models.sh first")
    OUT.mkdir(parents=True, exist_ok=True)
    for spec in VIEWMODELS:
        build_viewmodel(spec)
    build_props()
    print(f"models written to {OUT}")


main()
