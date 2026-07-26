#version 450

// Depth-only pass. There is no fragment shader: the depth buffer is the entire
// output, and the rasteriser writes it for free.

#include "frame.glsl"

layout(push_constant) uniform PushConstants {
    uint cascade;
} pc;

layout(location = 0) in vec3 in_position;

void main() {
    // world positions are baked into the buffer, so there is no model matrix
    gl_Position = frame.cascade_vp[pc.cascade] * vec4(in_position, 1.0);
}
