#version 450

#include "frame.glsl"

// Tracer quads arrive fully positioned in world space -- the CPU rebuilds them
// facing the camera every frame -- so this is a pass-through like the decals.

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_local;

layout(location = 0) out vec2 v_local;

void main() {
    gl_Position = frame.view_proj * vec4(in_position, 1.0);
    v_local = in_local;
}
