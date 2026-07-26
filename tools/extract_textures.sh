#!/usr/bin/env bash
# Unpacks ambientCG PBR sets into textures/<Name>/{Color,NormalGL,Roughness,AmbientOcclusion}.png
# Everything else in the archives (blend, usdc, mtlx, displacement, NormalDX) is skipped.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

maps=(Color NormalGL Roughness AmbientOcclusion)
count=0

for zip in *_1K-PNG.zip *_2K-PNG.zip *_4K-PNG.zip; do
    [ -e "$zip" ] || continue

    # PaintedPlaster009_1K-PNG.zip -> PaintedPlaster009
    name="${zip%%_*}"
    out="textures/$name"
    mkdir -p "$out"

    for map in "${maps[@]}"; do
        member=$(unzip -Z1 "$zip" | grep -E "_${map}\.png$" | head -1 || true)
        if [ -z "$member" ]; then
            echo "warn: $zip has no $map map" >&2
            continue
        fi
        unzip -p "$zip" "$member" > "$out/$map.png"
    done

    echo "$name"
    count=$((count + 1))
done

echo "extracted $count material(s) into textures/"
