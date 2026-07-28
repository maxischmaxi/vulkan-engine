#version 450

// Depth-only prepass over the world. Position is all it needs, and the
// invariant is the whole point: the shading pass re-runs this exact transform
// in world.vert and tests GREATER_OR_EQUAL against what this wrote, so the two
// must be bit-identical or the world gets holes.

#include "frame.glsl"

layout(location = 0) in vec3 in_position;

invariant gl_Position;

void main() {
    gl_Position = frame.view_proj * vec4(in_position, 1.0);
}
