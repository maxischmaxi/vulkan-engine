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

# unpacks the model archives and bakes them into models/*.mesh plus three more
# texture sets. Minutes, not seconds -- which is why `run` does not depend on it
# and a missing models/ directory panics with this recipe's name instead.
models:
    ./tools/extract_models.sh
    python3 tools/build_model_textures.py
    blender -b -P tools/convert_models.py

# -debug sets ODIN_DEBUG, which enables the validation layer and the HUD's debug
# tools (DEBUG_TOOLS defaults to it)
run: shaders
    odin run src -debug

# the same thing under the name the server recipe pairs with
client: run

# the dedicated server: headless, no shaders to compile, no Vulkan to validate
server:
    odin run src/server -debug

release-server:
    odin build src/server -out:vulkan-server -o:speed -no-bounds-check -disable-assert

# No ODIN_DEBUG, so no validation layer, no debug symbols and no debug tools.
#
# This is the only build any performance number may be quoted from: `run` carries
# the validation layer, which costs more than most of what one would measure.
#
# -o:aggressive is deliberately absent. It licenses float reassociation, and the
# physics compares floats exactly (physics/raycast.odin, physics/body.odin), so it
# could quietly change what the player collides with. Speed is not worth that.
release: shaders
    odin build src -out:vulkan -o:speed -no-bounds-check -disable-assert

# Optimised, but with the debug overlay and its shortcuts compiled in. The only
# way to look at something that misbehaves at full speed and not at -o:none.
#
# Keeps bounds checks: this is the build to reproduce a bug in, and an index that
# runs off the end should stop rather than corrupt something further away.
release-tools: shaders
    odin build src -out:vulkan -o:speed -define:DEBUG_TOOLS=true

# the packages with no Vulkan dependency, which is what makes them testable
test:
    odin test src/physics
    odin test src/game
    odin test src/protocol

check:
    odin check src -vet-unused -vet-shadowing
    odin check src/physics -vet-unused -vet-shadowing -no-entry-point
    odin check src/game -vet-unused -vet-shadowing -no-entry-point
    odin check src/protocol -vet-unused -vet-shadowing -no-entry-point
    odin check src/server -vet-unused -vet-shadowing

# One formatting to argue about instead of one per contributor.
fmt:
    odinfmt -w src

clean:
    rm -f shaders/*.spv vulkan src.bin
