#version 450

#include "frame.glsl"

// Bullet hole quads, already positioned in world space on the CPU -- the surface
// basis is trivial for axis-aligned geometry, so there is no model matrix.

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_local;
layout(location = 2) in float in_seed;
layout(location = 3) in float in_kind;

layout(location = 0) out vec2 v_local;
layout(location = 1) out float v_seed;
layout(location = 2) out float v_kind;

void main() {
    gl_Position = frame.view_proj * vec4(in_position, 1.0);
    v_local = in_local;
    v_seed = in_seed;
    v_kind = in_kind;
}
