default: run

# -e matters: without it a shader that fails to compile leaves the previous .spv
# in place, and the build happily bakes in stale bytecode.
#
# vulkan1.1, deliberately neither older nor newer. The subgroupOr in the light
# loop needs SPIR-V 1.3, which is exactly what this target emits, and every
# device the engine runs on accepts it because the engine requires Vulkan 1.3
# anyway. Raising the target to vulkan1.3 instead makes glslc compile every
# `discard` to DemoteToHelperInvocation -- a capability the device has to
# advertise -- so the two shaders that discard would add a feature requirement,
# on a project whose point is running on hardware that has as few of those as
# possible.
shaders:
    #!/usr/bin/env sh
    set -e
    for f in shaders/*.vert shaders/*.frag; do
        glslc -O --target-env=vulkan1.1 -I shaders/include "$f" -o "$f.spv"
    done

# unpacks the ambientCG zips in the project root into textures/<Name>/
textures:
    ./tools/extract_textures.sh

# downloads the CC0 sound packs into assets/sound_sources/ and curates them
# into sounds/, the runtime directory the audio bank reads
sounds:
    ./tools/fetch_sounds.sh
    python3 tools/synth_sounds.py

# just the generated grenade sounds -- seconds, no downloads. Run this after
# changing a number in tools/synth_sounds.py.
synth-sounds:
    python3 tools/synth_sounds.py

# unpacks the model archives and bakes them into models/*.mesh plus three more
# texture sets. Minutes, not seconds -- which is why `run` does not depend on it
# and a missing models/ directory panics with this recipe's name instead.
models:
    ./tools/extract_models.sh
    python3 tools/build_model_textures.py
    python3 tools/convert_characters.py
    blender -b -P tools/convert_models.py

# libsteam_api.so has SONAME libsteam_api.so, so the binary needs an rpath to
# find the vendored copy at runtime; dev builds point at the repo, release
# builds use $ORIGIN and ship the .so next to the binary
steam_rpath := "-extra-linker-flags:\"-Wl,-rpath," + justfile_directory() + "/steamworks/redistributable_bin/linux64\""

# -debug sets ODIN_DEBUG, which enables the validation layer and the HUD's debug
# tools (DEBUG_TOOLS defaults to it)
run: shaders
    odin run src -debug {{steam_rpath}}

# the same thing under the name the server recipe pairs with
client: run

# the dedicated server: headless, no shaders to compile, no Vulkan to validate
server:
    odin run src/server -debug {{steam_rpath}}

# ---------------------------------------------------------------- control plane
# The master directory and the fleet agent. The dev loop is: `just master` in
# one terminal, `just agent` in another (which builds the server binary the
# agent spawns), then clients with --master=127.0.0.1:27050 --join=t.

master min="1":
    odin run src/master -debug -- -token=dev -idle-stop=60 -floor=1 -min-humans={{min}}

# the dev fleet's server binary; the agent spawns copies of it
server-bin:
    odin build src/server -out:vulkan-server-dev -debug {{steam_rpath}}

agent: server-bin
    odin run src/agent -debug -- -master=127.0.0.1:27050 -token=dev -capacity=2 -server-bin=./vulkan-server-dev -insecure

release-master:
    odin build src/master -out:vulkan-master -o:speed -no-bounds-check -disable-assert

release-agent:
    odin build src/agent -out:vulkan-agent -o:speed -no-bounds-check -disable-assert

release-server:
    odin build src/server -out:vulkan-server -o:speed -no-bounds-check -disable-assert -define:STEAM_REQUIRED=true -extra-linker-flags:"-Wl,-rpath,'\$ORIGIN'"
    cp steamworks/redistributable_bin/linux64/libsteam_api.so .

# No ODIN_DEBUG, so no validation layer, no debug symbols and no debug tools.
#
# This is the only build any performance number may be quoted from: `run` carries
# the validation layer, which costs more than most of what one would measure.
#
# -o:aggressive is deliberately absent. It licenses float reassociation, and the
# physics compares floats exactly (physics/raycast.odin, physics/body.odin), so it
# could quietly change what the player collides with. Speed is not worth that.
# STEAM_REQUIRED makes Steam mandatory: the client relaunches through Steam,
# the server refuses -insecure and compiles the UDP listener out, and both
# ends force SDR relay routing so no IP is ever exchanged.
#
# STEAM_APP_ID still defaults to 480 (Spacewar). Before an actual Steam
# release both recipes need -define:STEAM_APP_ID=<real id>, and the packaging
# must NOT ship steam_appid.txt -- next to the binary it disables the
# relaunch-through-Steam gate; it exists for development only.
release: shaders
    odin build src -out:vulkan -o:speed -no-bounds-check -disable-assert -define:STEAM_REQUIRED=true -extra-linker-flags:"-Wl,-rpath,'\$ORIGIN'"
    cp steamworks/redistributable_bin/linux64/libsteam_api.so .

# Optimised, but with the debug overlay and its shortcuts compiled in. The only
# way to look at something that misbehaves at full speed and not at -o:none.
#
# Keeps bounds checks: this is the build to reproduce a bug in, and an index that
# runs off the end should stop rather than corrupt something further away.
release-tools: shaders
    odin build src -out:vulkan -o:speed -define:DEBUG_TOOLS=true {{steam_rpath}}

# the packages with no Vulkan dependency, which is what makes them testable
test:
    odin test src/physics
    odin test src/game
    odin test src/protocol
    odin test src/anticheat
    odin test src/mm

check:
    odin check src -vet-unused -vet-shadowing
    odin check src/physics -vet-unused -vet-shadowing -no-entry-point
    odin check src/game -vet-unused -vet-shadowing -no-entry-point
    odin check src/protocol -vet-unused -vet-shadowing -no-entry-point
    odin check src/anticheat -vet-unused -vet-shadowing -no-entry-point
    odin check src/mm -vet-unused -vet-shadowing -no-entry-point
    odin check src/master -vet-unused -vet-shadowing
    odin check src/agent -vet-unused -vet-shadowing
    odin check src/server -vet-unused -vet-shadowing
    odin check src -vet-unused -vet-shadowing -define:STEAM_REQUIRED=true
    odin check src/server -vet-unused -vet-shadowing -define:STEAM_REQUIRED=true

# One formatting to argue about instead of one per contributor.
fmt:
    odinfmt -w src

clean:
    rm -f shaders/*.spv vulkan vulkan-server vulkan-server-dev vulkan-master vulkan-agent libsteam_api.so src.bin
