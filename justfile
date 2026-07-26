default: run

shaders:
    #!/usr/bin/env sh
    for f in shaders/*.vert shaders/*.frag; do glslc "$f" -o "$f.spv"; done

# unpacks the ambientCG zips in the project root into textures/<Name>/
textures:
    ./tools/extract_textures.sh

# -debug sets ODIN_DEBUG, which is what enables the validation layer
run: shaders
    odin run src -debug

# no ODIN_DEBUG, so no validation layer and no debug symbols
release: shaders
    odin build src -out:vulkan -o:speed

clean:
    rm -f shaders/*.spv vulkan
