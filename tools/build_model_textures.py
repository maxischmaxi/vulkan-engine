#!/usr/bin/env python3
"""Turns the model archives' textures into ambientCG-shaped sets under textures/.

The engine already has one texture pipeline: every set is a directory holding
Color/NormalGL/Roughness/AmbientOcclusion at the array's layer size, and
create_texture_arrays tiles anything smaller. Model textures are not tileable,
so they are written at exactly the layer size here and the tiling never kicks in.

Three sets come out of this:

  RetroWeapons  one 2x2 atlas of the retro pack's 512-ish albedo maps. Four
                separate layers would cost four times the VRAM for textures that
                are mostly empty, and the pack ships no normal or roughness maps
                at all -- those are written flat.
  PropPalette   the 12x12 palette the Collada props are mapped onto, blown up
                with nearest so the colour fields stay flat.
  GunPalette    one swatch per gun-pack material name; see gun_palette.py.
  ModularPalette  the modular prototyping pack's 8x8 palette, same treatment
                as PropPalette.
  CharPalette   two grey swatches for the player mannequin. The team colour is
                a material tint, not a swatch -- see build_char_palette.
  Nade*/BombC4  one set per grenade and the C4, straight from the explosives
                pack's own PBR maps. The only pack here that ships UVs, so it
                is the only one that does not go through a palette.

Run through `just models`; convert_models.py assumes the atlas layout below.
"""

import sys
from pathlib import Path

from PIL import Image

import gun_palette

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
OUT = ROOT / "textures"

# Must match the world texture arrays, which size themselves from the largest
# ambientCG set (1K). A model layer larger than that would only be downsampled.
LAYER = 1024

# The atlas: four 512 tiles, addressed by name from convert_models.py. Keep the
# order in sync with ATLAS_TILES there.
ATLAS = LAYER // 2
TILES = {
    "rifle": (0, 0),
    "pistol": (1, 0),
    "arms": (0, 1),
    "projectiles": (1, 1),
}


def load(path):
    img = Image.open(path)
    return img.convert("RGBA") if img.mode != "RGBA" else img


def fit(img, size):
    """Nearest when the factor is a whole number, Lanczos otherwise.

    Retro art is pixel art: doubling 256 to 512 with a smooth filter throws away
    the one property the texture has. A 390 source has no whole factor, so it
    gets the good resampler instead.
    """
    if img.width == size and img.height == size:
        return img
    whole = size % img.width == 0 and size % img.height == 0
    shrink_whole = img.width % size == 0 and img.height % size == 0
    resample = Image.NEAREST if (whole or shrink_whole) else Image.LANCZOS
    if shrink_whole and img.width > size:
        # Box-averaging a whole-number downscale keeps more than point sampling
        resample = Image.BOX
    return img.resize((size, size), resample)


def write(set_name, maps):
    out = OUT / set_name
    out.mkdir(parents=True, exist_ok=True)
    for name, img in maps.items():
        img.save(out / f"{name}.png")
    print(f"  {set_name}: {', '.join(maps)}")


def flat_normal(size):
    # +Z in tangent space; the loader takes the top byte of each channel
    return Image.new("RGB", (size, size), (128, 128, 255))


def constant(size, value):
    return Image.new("L", (size, size), value)


def build_retro_weapons():
    src = ASSETS / "retro" / "textures"
    sources = {
        "rifle": src / "Rifle_01_Albedo.png",
        "pistol": src / "Pistol_01_Albedo.png",
        "arms": src / "FPS_Arms_Albedo.png",
        "projectiles": src / "Projectiles_Albedo.png",
    }

    atlas = Image.new("RGB", (LAYER, LAYER), (0, 0, 0))
    for name, (tx, ty) in TILES.items():
        path = sources[name]
        if not path.exists():
            print(f"  warn: {path.name} missing, tile {name} stays black")
            continue
        tile = fit(load(path), ATLAS).convert("RGB")
        atlas.paste(tile, (tx * ATLAS, ty * ATLAS))

    write(
        "RetroWeapons",
        {
            "Color": atlas,
            "NormalGL": flat_normal(LAYER),
            # 0.55 reads as worn polymer and gunmetal under this lighting model;
            # the per-material roughness multiplier tunes it further.
            "Roughness": constant(LAYER, 140),
            "AmbientOcclusion": constant(LAYER, 255),
        },
    )


def build_prop_palette():
    # Yellow is the warmest of the five and the only one that sits in dust2's
    # palette; the others would need the material tint to fight them back.
    src = ASSETS / "props" / "palettes" / "Palette_Yellow.png"
    palette = load(src).convert("RGB")
    # 12 does not divide 1024, so scale in two steps: nearest to a whole
    # multiple, then crop-free nearest again. Simplest is a plain nearest resize.
    palette = palette.resize((LAYER, LAYER), Image.NEAREST)
    write(
        "PropPalette",
        {
            "Color": palette,
            "NormalGL": flat_normal(LAYER),
            "Roughness": constant(LAYER, 200),
            "AmbientOcclusion": constant(LAYER, 255),
        },
    )


def build_modular_palette():
    # One pixel per colour field; nearest keeps them flat, like PropPalette.
    src = ASSETS / "modular" / "texture.png"
    palette = load(src).convert("RGB")
    palette = palette.resize((LAYER, LAYER), Image.NEAREST)
    write(
        "ModularPalette",
        {
            "Color": palette,
            "NormalGL": flat_normal(LAYER),
            "Roughness": constant(LAYER, 200),
            "AmbientOcclusion": constant(LAYER, 255),
        },
    )


def build_gun_palette():
    # One flat-colour swatch per (gun, material) across the roster; the mesh
    # UVs point at swatch centres, exactly like the prop palette. Colour comes
    # from the MTL Kd values, which are linear -- the albedo array is sRGB, so
    # they are encoded here or every gun renders near-black.
    if not (ASSETS / "guns" / "obj").exists():
        sys.exit("assets/guns missing -- run tools/extract_models.sh first")
    grid = gun_palette.GRID
    # Unused cells stay mid-grey: a wrong UV then reads as grey, not as a
    # neighbouring material's colour.
    color = Image.new("RGB", (grid, grid), (128, 128, 128))
    rough = Image.new("L", (grid, grid), 190)
    for index, (mat_name, rgb) in enumerate(gun_palette.swatches(ASSETS)):
        srgb = tuple(round(gun_palette.linear_to_srgb(c) * 255) for c in rgb)
        color.putpixel((index % grid, index // grid), srgb)
        rough.putpixel((index % grid, index // grid), gun_palette.roughness_byte(mat_name))
    write(
        "GunPalette",
        {
            "Color": color.resize((LAYER, LAYER), Image.NEAREST),
            "NormalGL": flat_normal(LAYER),
            "Roughness": rough.resize((LAYER, LAYER), Image.NEAREST),
            "AmbientOcclusion": constant(LAYER, 255),
        },
    )


def build_char_palette():
    # The character's two swatches, and they are deliberately colourless. The
    # mannequin has no textures at all, so the only thing this layer contributes
    # is a surface to tint -- and the team colours live in MATERIALS on the Odin
    # side, next to the ones the menu and the HUD use. Putting colour here too
    # would mean two places to change it and one of them silently wrong.
    #
    # Keep the cell order in sync with PALETTE_CELLS in convert_characters.py.
    grid = 2
    color = Image.new("RGB", (grid, grid), (128, 128, 128))
    color.putpixel((0, 0), (196, 196, 196))  # char_main
    color.putpixel((1, 0), (150, 150, 150))  # char_joints
    write(
        "CharPalette",
        {
            "Color": color.resize((LAYER, LAYER), Image.NEAREST),
            "NormalGL": flat_normal(LAYER),
            "Roughness": constant(LAYER, 175),
            "AmbientOcclusion": constant(LAYER, 255),
        },
    )


# The explosives pack, the one archive here with real UVs and PBR maps. One
# texture set per model that the game actually holds; the rest of the pack is on
# disk as geometry and points at the palette's plain swatch until somebody needs
# it (see build_pack_models in convert_models.py).
#
# `tiles` splits a set into a 2x2 atlas when a model's materials each ship their
# own maps -- the molotov is bottle, wick and liquid, and three layers for one
# bottle is not a trade worth making. Keep the tile order in sync with
# EXPLOSIVE_TILES in convert_models.py.
EXPLOSIVE_SETS = {
    "NadeFrag": {"source": "FragGrenade"},
    "NadeFlash": {"source": "Flashbang"},
    "NadeSmoke": {"source": "Smoke_Grenade"},
    "BombC4": {"source": "C4"},
    "NadeMolotov": {
        "tiles": {
            "Bottle": (0, 0),
            # The pack ships this one with the r missing off Base_Color.
            "Fabric": (1, 0),
            "Liquid": (0, 1),
        }
    },
}


def explosive_map(stem, kind):
    """One of a pack model's maps, or None. The pack is not consistent about
    its own names -- Fabric's albedo is 'Base_Colo' -- so every candidate the
    archive actually contains is tried."""
    names = {
        "color": ("Base_Color", "Base_Colo"),
        "normal": ("Normal_DirectX", "Normal"),
        "rough": ("Roughness",),
    }[kind]
    for suffix in names:
        path = ASSETS / "explosives" / f"{stem}_{suffix}.png"
        if path.exists():
            return path
    return None


def directx_to_gl(img):
    """DirectX normal maps run green down the surface, OpenGL runs it up, and
    the engine's array is NormalGL. Without the flip every lit bump on these
    models reads as a dent -- subtle enough to spend an afternoon blaming the
    shader for."""
    r, g, b = img.convert("RGB").split()
    return Image.merge("RGB", (r, g.point(lambda v: 255 - v), b))


def explosive_maps(stem, size):
    """Colour, normal and roughness for one pack model, at `size`. Missing maps
    fall back the way the retro pack's do: flat normal, mid roughness."""
    color_path = explosive_map(stem, "color")
    if color_path is None:
        print(f"  warn: no albedo for {stem}, tile stays grey")
        return None
    color = fit(load(color_path), size).convert("RGB")

    normal_path = explosive_map(stem, "normal")
    normal = (
        directx_to_gl(fit(load(normal_path), size))
        if normal_path
        else flat_normal(size)
    )

    rough_path = explosive_map(stem, "rough")
    rough = (
        fit(load(rough_path), size).convert("L") if rough_path else constant(size, 190)
    )
    return color, normal, rough


def build_explosives():
    if not (ASSETS / "explosives").exists():
        sys.exit("assets/explosives missing -- run tools/extract_models.sh first")

    for set_name, spec in EXPLOSIVE_SETS.items():
        if "tiles" in spec:
            color = Image.new("RGB", (LAYER, LAYER), (128, 128, 128))
            normal = flat_normal(LAYER)
            rough = constant(LAYER, 190)
            for stem, (tx, ty) in spec["tiles"].items():
                maps = explosive_maps(stem, ATLAS)
                if maps is None:
                    continue
                at = (tx * ATLAS, ty * ATLAS)
                color.paste(maps[0], at)
                normal.paste(maps[1], at)
                rough.paste(maps[2], at)
        else:
            maps = explosive_maps(spec["source"], LAYER)
            if maps is None:
                continue
            color, normal, rough = maps

        write(
            set_name,
            {
                "Color": color,
                "NormalGL": normal,
                "Roughness": rough,
                # The pack ships no occlusion maps; the material's own shading
                # carries it, the way the retro sets do.
                "AmbientOcclusion": constant(LAYER, 255),
            },
        )


def main():
    if not ASSETS.exists():
        sys.exit("assets/ missing -- run tools/extract_models.sh first")
    print(f"model textures at {LAYER}x{LAYER}:")
    build_retro_weapons()
    build_prop_palette()
    build_modular_palette()
    build_gun_palette()
    build_char_palette()
    build_explosives()


if __name__ == "__main__":
    main()
