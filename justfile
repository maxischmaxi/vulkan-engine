default: run

shaders:
    #!/usr/bin/env sh
    for f in shaders/*.vert shaders/*.frag; do glslc "$f" -o "$f.spv"; done

run: shaders
    odin run src

clean:
    rm -f shaders/*.spv
