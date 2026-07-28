#version 450

#include "frame.glsl"

// Models into a cascade. Position and the instance transform, nothing else --
// the depth pass has no use for the rest of the vertex.
layout(push_constant) uniform PushConstants {
    uint cascade;
} pc;

layout(location = 0) in vec3 in_position;

layout(location = 1) in vec4 in_model0;
layout(location = 2) in vec4 in_model1;
layout(location = 3) in vec4 in_model2;
layout(location = 4) in vec4 in_model3;

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);
    gl_Position = frame.cascade_vp[pc.cascade] * model * vec4(in_position, 1.0);
}
