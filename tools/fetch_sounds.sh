#!/usr/bin/env sh
# Downloads the CC0 sound packs and curates them into sounds/, the runtime
# directory the audio bank reads. Everything here is CC0 (no attribution
# required); provenance still lands in sounds/ATTRIBUTION.md.
#
# Effects are converted to mono ogg -- miniaudio's spatializer pans mono
# cleanly, stereo files defeat positioning. Music stays stereo. Leading
# silence is trimmed so a footstep does not feel laggy.
set -e

SRC=assets/sound_sources
OUT=sounds

mkdir -p "$SRC" \
    "$OUT/weapons" "$OUT/footsteps" "$OUT/music" "$OUT/ui" "$OUT/ambient"

# ---------------------------------------------------------------- downloads

dl() {
    [ -f "$SRC/$2" ] && return
    echo "fetch $2"
    curl -sL --fail -o "$SRC/$2" "$1"
}

dl "https://opengameart.org/sites/default/files/Prepared%20SFX%20Library.7z" firearm_library.7z
dl "https://opengameart.org/sites/default/files/%5Bkdd%5DDifferentSteps_0.zip" kdd_steps.zip
dl "https://opengameart.org/sites/default/files/awesomeness.wav" menu_music.wav
dl "https://opengameart.org/sites/default/files/slightscreams.7z" slightscreams.7z
dl "https://opengameart.org/sites/default/files/sfx_loops.zip" sfx_loops.zip
dl "https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip" kenney_interface.zip
dl "https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip" kenney_impact.zip
dl "https://kenney.nl/media/pages/assets/rpg-audio/8e99002d76-1677590336/kenney_rpg-audio.zip" kenney_rpg.zip
dl "https://kenney.nl/media/pages/assets/music-jingles/f37e530b9e-1677590399/kenney_music-jingles.zip" kenney_jingles.zip

ex() {
    [ -d "$SRC/$1" ] && return
    echo "extract $1"
    case "$2" in
    *.7z) 7z x -y -o"$SRC/$1" "$SRC/$2" >/dev/null ;;
    *) unzip -qo "$SRC/$2" -d "$SRC/$1" ;;
    esac
}

ex firearm firearm_library.7z
ex kdd_steps kdd_steps.zip
ex slightscreams slightscreams.7z
ex sfx_loops sfx_loops.zip
ex kenney_interface kenney_interface.zip
ex kenney_impact kenney_impact.zip
ex kenney_rpg kenney_rpg.zip
ex kenney_jingles kenney_jingles.zip

# ----------------------------------------------------------------- curation

FIREARM="$SRC/firearm/Prepared SFX Library"
RPG="$SRC/kenney_rpg/Audio"
UI="$SRC/kenney_interface/Audio"
IMPACT="$SRC/kenney_impact/Audio"
JINGLE="$SRC/kenney_jingles/Audio"

TRIM="silenceremove=start_periods=1:start_threshold=-45dB"

# mono effect, leading silence trimmed
fx() {
    ffmpeg -loglevel error -y -i "$1" -ac 1 -af "$TRIM" -c:a libvorbis -q:a 4 "$OUT/$2"
}

# One gunshot per file. The firearm library records several takes back to back
# in one file; played whole, every emit fires phantom follow-up shots for up to
# 17 seconds. Cut at the first stretch of silence after the report -- the tail
# is already below the threshold there, so the cut lands on near-silence.
shot() {
    ffmpeg -loglevel error -y -i "$1" -ac 1 \
        -af "$TRIM,silenceremove=stop_periods=1:stop_threshold=-45dB:stop_duration=0.3" \
        -c:a libvorbis -q:a 4 "$OUT/$2"
}

# mono effect, pitched by a rate factor: cheap extra variants from one take
fxp() {
    ffmpeg -loglevel error -y -i "$1" -ac 1 \
        -af "$TRIM,asetrate=44100*$3,aresample=44100" -c:a libvorbis -q:a 4 "$OUT/$2"
}

# stereo, untouched dynamics: music and jingles
mus() {
    ffmpeg -loglevel error -y -i "$1" -c:a libvorbis -q:a 5 "$OUT/$2"
}

echo "curate weapons"
shot "$FIREARM/Walther PPQ/X_39P.wav" weapons/glock_01.ogg
shot "$FIREARM/1911/A_42P.wav" weapons/usp_01.ogg
shot "$FIREARM/Smith & Wesson 642/V_27P.wav" weapons/deagle_01.ogg
shot "$FIREARM/PPSh/P_30P.wav" weapons/mac10_01.ogg
shot "$FIREARM/Carl Gustav M45/G_31P.wav" weapons/mp9_01.ogg
shot "$FIREARM/Nova/O_21P.wav" weapons/nova_01.ogg
shot "$FIREARM/AK-47/C_28P.wav" weapons/ak_01.ogg
shot "$FIREARM/AR-15/D_32P.wav" weapons/m4_01.ogg
shot "$FIREARM/Tikka/W_29P.wav" weapons/awp_01.ogg
fx "$RPG/metalClick.ogg" weapons/dryfire_01.ogg
fx "$RPG/metalLatch.ogg" weapons/reload_start_01.ogg
fx "$RPG/beltHandle1.ogg" weapons/reload_end_01.ogg
fx "$RPG/clothBelt.ogg" weapons/draw_01.ogg
fx "$RPG/knifeSlice.ogg" weapons/knife_01.ogg
fx "$RPG/knifeSlice2.ogg" weapons/knife_02.ogg

echo "curate footsteps"
fx "$SRC/kdd_steps/stone01.ogg" footsteps/step_01.ogg
fx "$SRC/kdd_steps/gravel.ogg" footsteps/step_02.ogg
fxp "$SRC/kdd_steps/stone01.ogg" footsteps/step_03.ogg 0.94
fxp "$SRC/kdd_steps/gravel.ogg" footsteps/step_04.ogg 1.06
fx "$RPG/cloth1.ogg" footsteps/jump_01.ogg
fx "$IMPACT/impactPunch_medium_000.ogg" footsteps/land_01.ogg

echo "curate ui"
fx "$UI/click_001.ogg" ui/click_01.ogg
fx "$UI/click_002.ogg" ui/hit_01.ogg
fx "$UI/confirmation_001.ogg" ui/kill_01.ogg
fx "$UI/confirmation_002.ogg" ui/buy_01.ogg
fx "$UI/bong_001.ogg" ui/bomb_planted_01.ogg
fx "$SRC/slightscreams/slightscream-01.flac" ui/hurt_01.ogg
fx "$SRC/slightscreams/slightscream-02.flac" ui/hurt_02.ogg
fx "$SRC/slightscreams/slightscream-03.flac" ui/hurt_03.ogg
mus "$JINGLE/Steel jingles/jingles_STEEL00.ogg" ui/round_start_01.ogg
mus "$JINGLE/Steel jingles/jingles_STEEL04.ogg" ui/round_end_01.ogg

echo "curate music and ambient"
mus "$SRC/menu_music.wav" music/menu.ogg
fx "$SRC/sfx_loops/ambient_01.ogg" ambient/ambient_01.ogg

cat >"$OUT/ATTRIBUTION.md" <<'EOF'
# Sound provenance

Everything in this directory is CC0 (public domain); attribution is not
required, recorded here anyway. Files were converted to ogg (effects mono,
music stereo) and trimmed by tools/fetch_sounds.sh.

| sounds/ | source | author | license |
|---|---|---|---|
| weapons/*_01 gunshots | The Free Firearm Sound Library, opengameart.org/content/the-free-firearm-sound-library | Ben Jaszczak, Brian Nelson, Kevin Heras, Matthew Nanney | CC0 |
| weapons/dryfire, reload_*, draw, knife_* | RPG Audio, kenney.nl/assets/rpg-audio | Kenney | CC0 |
| footsteps/step_* | Different steps..., opengameart.org/content/different-steps-on-wood-stone-leaves-gravel-and-mud | qat / kdd | CC0 |
| footsteps/jump_01 | RPG Audio, kenney.nl | Kenney | CC0 |
| footsteps/land_01 | Impact Sounds, kenney.nl/assets/impact-sounds | Kenney | CC0 |
| ui/click, hit, kill, buy, bomb_planted | Interface Sounds, kenney.nl/assets/interface-sounds | Kenney | CC0 |
| ui/hurt_* | 15 vocal male strain/hurt/pain/jump sounds, opengameart.org/content/15-vocal-male-strainhurtpainjump-sounds | Nicholas Vasilev | CC0 |
| ui/round_* | Music Jingles, kenney.nl/assets/music-jingles | Kenney | CC0 |
| music/menu.ogg | Menu Music ("awesomeness"), opengameart.org/content/menu-music | mrpoly | CC0 |
| ambient/ambient_01.ogg | 30 CC0 SFX loops, opengameart.org/content/30-cc0-sfx-loops | rubberduck | CC0 |
EOF

echo "done: $(find "$OUT" -name '*.ogg' | wc -l) files in $OUT/"
