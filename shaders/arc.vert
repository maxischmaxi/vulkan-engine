#version 450

#include "frame.glsl"

// The throw preview arrives fully positioned in world space -- the CPU rebuilds
// the ribbon facing the camera every frame, and the ring is laid on the surface
// it marks -- so this is a pass-through like the tracers.

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec2 in_local;
layout(location = 2) in vec2 in_params; // shape (0 ribbon, 1 ring), opacity

layout(location = 0) out vec2 v_local;
layout(location = 1) out vec2 v_params;

void main() {
    gl_Position = frame.view_proj * vec4(in_position, 1.0);
    v_local = in_local;
    v_params = in_params;
}
