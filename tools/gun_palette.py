"""The gun pack's colour palette, shared between the two build scripts.

The Quaternius models carry no UVs and no textures -- colour lives in the OBJ
MTL files as one Kd per named material, and every material name has the same
Kd across the whole pack (verified: all 14 names are uniform). So the palette
is one swatch per material NAME, shared by every gun: build_model_textures.py
bakes the swatches into a texture, convert_models.py writes the matching UVs
into the meshes. Both must agree, so both import this.

The FBX files reference names their own MTL sometimes lacks (AssaultRifle_1's
FBX has Wood, its MTL does not), which is the other reason the palette is the
union over every MTL in the pack rather than per gun.
"""

from pathlib import Path

# Swatch grid: 4x4 cells over the 1024 layer = 256px per swatch, flat colour.
# 14 names today; the assert below trips if the pack ever outgrows it.
GRID = 4

# The last cell, reserved rather than coloured: models that are on disk but have
# no texture set of their own point every UV here and come out plain grey. Being
# a named cell rather than "whatever is left over" is what keeps a growing pack
# from quietly stealing it.
PLAIN_INDEX = GRID * GRID - 1

# Materials that read as bare metal get the metallic engine material; everything
# else (polymer, wood, glass) stays dielectric. Roughness is per-swatch in the
# texture, so this split only decides metalness.
METAL_NAMES = {"Metal", "DarkMetal", "LightMetal", "LightMetal2"}

_ROUGHNESS = {name: 80 for name in METAL_NAMES}
_ROUGHNESS.update({"Glass": 60, "Wood": 210, "DarkWood": 210})
_ROUGHNESS_DEFAULT = 190  # polymer


def engine_material(mat_name):
    return "gun_metal" if mat_name in METAL_NAMES else "gun_matte"


def roughness_byte(mat_name):
    return _ROUGHNESS.get(mat_name, _ROUGHNESS_DEFAULT)


def linear_to_srgb(c):
    """One channel, 0..1 linear to 0..1 sRGB. The MTL Kd values are linear
    (Blender 2.79 export); the albedo array is R8G8B8A8_SRGB."""
    if c <= 0.0031308:
        return 12.92 * c
    return 1.055 * c ** (1.0 / 2.4) - 0.055


def parse_mtl(path):
    """name -> (r, g, b) linear, in file order."""
    out = {}
    name = None
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "newmtl":
            name = parts[1]
        elif parts[0] == "Kd" and name is not None:
            out[name] = tuple(float(v) for v in parts[1:4])
    return out


def swatches(assets_dir):
    """[(material name, linear rgb)] over the whole pack, sorted by name --
    the order that defines the swatch indices."""
    by_name = {}
    for mtl in sorted((Path(assets_dir) / "guns" / "obj").glob("*.mtl")):
        for name, rgb in parse_mtl(mtl).items():
            seen = by_name.setdefault(name, rgb)
            assert seen == rgb, f"material {name} has two colours in the pack"
    out = sorted(by_name.items())
    assert len(out) < GRID * GRID, (
        f"{len(out)} swatches leave no room for the plain cell in the "
        f"{GRID}x{GRID} grid"
    )
    return out


def swatch_uv(index):
    """Centre of a swatch cell, in UV space with v running down the image."""
    col, row = index % GRID, index // GRID
    return ((col + 0.5) / GRID, (row + 0.5) / GRID)
