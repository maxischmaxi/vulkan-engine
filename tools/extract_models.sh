#!/usr/bin/env bash
# Unpacks the model archives into assets/, which is what convert_models.py reads.
#
# Only the members the converter actually touches are extracted: the weapon pack
# alone is half a gigabyte and nine tenths of it is animation FBX we do not read
# yet. Everything lands stripped of its archive-internal directory layout, so the
# converter's paths stay short.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

retro=RetroWeaponPack_V1.zip
props=Models.zip
palettes=Palettes.zip
psx=psx-first-person-arms-free-game-assets.zip
guns=UltimateGunPackByQuaternius.zip
modular=ModularGameAssetsForPrototyping.zip
characters="Universal Animation Library 2[Source].zip"

# An archive may be deleted once its assets are on disk; a re-run then keeps
# what is extracted. Only a pack missing both archive and assets is an error.
need() {
    [ -e "$1" ] || [ -e "$2" ] || {
        echo "missing $1 -- put the archive in the project root" >&2
        exit 1
    }
}

# unzip -j drops the paths; -o overwrites so a re-run is idempotent
pull() {
    local archive="$1" out="$2"; shift 2
    mkdir -p "$out"
    unzip -joq "$archive" "$@" -d "$out"
}

need "$retro" assets/retro/blend
need "$props" assets/props/models
need "$palettes" assets/props/palettes
need "$guns" assets/guns/obj
need "$modular" assets/modular/pieces
need "$characters" assets/characters

# The blend files are the good source: arms and gun sit in one scene, already
# posed and animated. The FBX are the fallback for anything the blend lacks.
if [ -e "$retro" ]; then
    pull "$retro" assets/retro/blend \
        "Assets/RetroWeaponsPack/FP_Arms/BlendFiles/FP_Arms_Rifle_01_Anims.blend" \
        "Assets/RetroWeaponsPack/FP_Arms/BlendFiles/FP_Arms_Pistol_01_Anims.blend" \
        "Assets/RetroWeaponsPack/Guns/Pistol_01/BlendFile/Pistol_01.blend" \
        "Assets/RetroWeaponsPack/Guns/Rifle_01/BlendFile/Rifle_01.blend"

    pull "$retro" assets/retro/textures \
        "Assets/RetroWeaponsPack/FP_Arms/Texture/FPS_Arms_Albedo.png" \
        "Assets/RetroWeaponsPack/Guns/Rifle_01/Textures/Rifle_01_Albedo.png" \
        "Assets/RetroWeaponsPack/Guns/Pistol_01/Textures/Pistol_01_Albedo.png" \
        "Assets/RetroWeaponsPack/Guns/AdditionalMeshes/Projectiles/Texture/Projectiles_Albedo.png"

    pull "$retro" assets/retro/fx \
        "Assets/RetroWeaponsPack/FX/Textures/MuzzleFlash.png"
fi

[ -e "$props" ] && pull "$props" assets/props/models "Models/*.dae"
[ -e "$palettes" ] && pull "$palettes" assets/props/palettes "Palettes/*.png"

# The whole gun pack lands on disk; the converter reads only the roster FBX,
# and gun_palette.py reads the MTL files for the material colours.
if [ -e "$guns" ]; then
    pull "$guns" assets/guns/fbx "FBX/*.fbx"
    pull "$guns" assets/guns/obj "OBJ/*.obj" "OBJ/*.mtl"
    pull "$guns" assets/guns/blend "Blends/*.blend"
    pull "$guns" assets/guns "Preview.jpg"
fi

# Not used by the converter -- unpacked because the archive was handed over with
# the rest, and a second set of arms is worth having on disk.
if [ -e "$psx" ]; then
    pull "$psx" assets/psx_arms "arms_rig.glb" "arms_01.png" "arms_gloves_01.png"
fi

# The modular prototyping pieces: the converter reads a curated roster from
# pieces/, and texture.png is the 8x8 palette every piece's UVs point into.
if [ -e "$modular" ]; then
    pull "$modular" assets/modular/pieces \
        "Free 3D Modular Game Assets For Prototyping/Pieces/*.fbx"
    pull "$modular" assets/modular \
        "Free 3D Modular Game Assets For Prototyping/texture.png" \
        "Free 3D Modular Game Assets For Prototyping/License.txt"
fi

# The player character. UAL2.glb holds the mannequin, its 65-joint rig and all
# 134 animations in place; UAL2_RM.glb is the same library with root motion left
# in, and it is unpacked for exactly one number per clip -- how far the root
# travels in one cycle, which is what drives the walk cycle off distance instead
# of a guessed stride length. The FBX beside them are the same content for
# engines that want it that way, and the female mannequin has no animations of
# its own, so neither is unpacked.
if [ -e "$characters" ]; then
    pull "$characters" assets/characters "Unreal-Godot/UAL2.glb" "Unreal-Godot/UAL2_RM.glb" "License.txt"
fi

echo "assets/ ready:"
du -sh assets/* 2>/dev/null || true
