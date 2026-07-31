#version 450

#include "frame.glsl"

// Characters into a cascade. Position and the skinning, nothing else -- but the
// skinning is not optional here the way the surface is: a shadow cast from the
// bind pose would stand still while the character it belongs to walks.
layout(push_constant) uniform PushConstants {
    uint cascade;
} pc;

layout(std430, set = 0, binding = 4) readonly buffer Joints {
    mat4 joints[];
};

layout(location = 0) in vec3 in_position;
layout(location = 1) in uvec4 in_joints;
layout(location = 2) in vec4 in_weights;

layout(location = 3) in vec4 in_model0;
layout(location = 4) in vec4 in_model1;
layout(location = 5) in vec4 in_model2;
layout(location = 6) in vec4 in_model3;
layout(location = 7) in uvec2 in_indices; // joint block base, material offset

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);
    uint base = in_indices.x;

    mat4 skin = in_weights.x * joints[base + in_joints.x]
              + in_weights.y * joints[base + in_joints.y]
              + in_weights.z * joints[base + in_joints.z]
              + in_weights.w * joints[base + in_joints.w];

    gl_Position = frame.cascade_vp[pc.cascade] * model * (skin * vec4(in_position, 1.0));
}
