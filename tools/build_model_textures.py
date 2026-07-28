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
  ThrowingKnife the one asset with a real PBR set, downsampled from 4096.
  PropPalette   the 12x12 palette the Collada props are mapped onto, blown up
                with nearest so the colour fields stay flat.

Run through `just models`; convert_models.py assumes the atlas layout below.
"""

import sys
from pathlib import Path

from PIL import Image

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


def build_knife():
    src = ASSETS / "knife"
    albedo = fit(load(src / "throwing_knife_albedo.png"), LAYER).convert("RGB")
    normal = fit(load(src / "throwing_knife_normal.png"), LAYER).convert("RGB")
    rough = fit(load(src / "throwing_knife_roughness.png"), LAYER).convert("L")
    ao = fit(load(src / "throwing_knife_ao.png"), LAYER).convert("L")
    write(
        "ThrowingKnife",
        {"Color": albedo, "NormalGL": normal, "Roughness": rough, "AmbientOcclusion": ao},
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


def main():
    if not ASSETS.exists():
        sys.exit("assets/ missing -- run tools/extract_models.sh first")
    print(f"model textures at {LAYER}x{LAYER}:")
    build_retro_weapons()
    build_knife()
    build_prop_palette()


if __name__ == "__main__":
    main()
