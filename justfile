default: run

# -e matters: without it a shader that fails to compile leaves the previous .spv
# in place, and the build happily bakes in stale bytecode.
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

# no ODIN_DEBUG, so no validation layer, no debug symbols and no debug tools
release: shaders
    odin build src -out:vulkan -o:speed

# Optimised, but with the debug overlay and its shortcuts compiled in. The only
# way to look at something that misbehaves at full speed and not at -o:none.
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
