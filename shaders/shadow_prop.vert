#version 450

// Instanced boxes into a shadow cascade. Depth-only, so there is no fragment
// shader and nothing but the position matters.

#include "frame.glsl"

layout(push_constant) uniform PushConstants {
    uint cascade;
} pc;

layout(location = 0) in vec3 in_position;

// per instance -- same buffer as the main prop pass, only fewer attributes read
layout(location = 1) in vec4 in_model0;
layout(location = 2) in vec4 in_model1;
layout(location = 3) in vec4 in_model2;
layout(location = 4) in vec4 in_model3;

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);
    gl_Position = frame.cascade_vp[pc.cascade] * model * vec4(in_position, 1.0);
}
