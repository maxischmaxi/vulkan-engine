default: run

# -e matters: without it a shader that fails to compile leaves the previous .spv
# in place, and the build happily bakes in stale bytecode.
#
# The target env is left at glslc's default rather than raised to vulkan1.3.
# Raising it makes glslc compile every `discard` to DemoteToHelperInvocation,
# which is a capability the device has to advertise -- so the two shaders that
# discard would add a feature requirement, on a project whose point is running on
# hardware that has as few of those as possible. The optimiser gains nothing on
# shaders this small in exchange.
shaders:
    #!/usr/bin/env sh
    set -e
    for f in shaders/*.vert shaders/*.frag; do
        glslc -O -I shaders/include "$f" -o "$f.spv"
    done

# unpacks the ambientCG zips in the project root into textures/<Name>/
textures:
    ./tools/extract_textures.sh

# -debug sets ODIN_DEBUG, which enables the validation layer and the HUD's debug
# tools (DEBUG_TOOLS defaults to it)
run: shaders
    odin run src -debug

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

# src/physics has no Vulkan dependency, which is what makes it testable at all
test:
    odin test src/physics

check:
    odin check src -vet-unused -vet-shadowing
    odin check src/physics -vet-unused -vet-shadowing -no-entry-point

# One formatting to argue about instead of one per contributor.
fmt:
    odinfmt -w src

clean:
    rm -f shaders/*.spv vulkan src.bin
