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
knife=ThrowingKnife.zip
props=Models.zip
palettes=Palettes.zip
psx=psx-first-person-arms-free-game-assets.zip

need() {
    [ -e "$1" ] || { echo "missing $1 -- put the archive in the project root" >&2; exit 1; }
}

# unzip -j drops the paths; -o overwrites so a re-run is idempotent
pull() {
    local archive="$1" out="$2"; shift 2
    mkdir -p "$out"
    unzip -joq "$archive" "$@" -d "$out"
}

need "$retro"; need "$knife"; need "$props"; need "$palettes"

# The blend files are the good source: arms and gun sit in one scene, already
# posed and animated. The FBX are the fallback for anything the blend lacks.
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

pull "$knife" assets/knife "ThrowingKnife/*"

pull "$props" assets/props/models "Models/*.dae"
pull "$palettes" assets/props/palettes "Palettes/*.png"

# Not used by the converter -- unpacked because the archive was handed over with
# the rest, and a second set of arms is worth having on disk.
if [ -e "$psx" ]; then
    pull "$psx" assets/psx_arms "arms_rig.glb" "arms_01.png" "arms_gloves_01.png"
fi

echo "assets/ ready:"
du -sh assets/* 2>/dev/null || true
