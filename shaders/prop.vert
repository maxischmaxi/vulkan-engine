#version 450

#include "frame.glsl"

// Instanced unit cube. The view-projection is a push constant rather than the
// frame uniform so the same pipeline draws both world props and the viewmodel,
// which uses a narrower field of view.
layout(push_constant) uniform PushConstants {
    mat4 view_proj;
} pc;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

// per instance
layout(location = 2) in vec4 in_model0;
layout(location = 3) in vec4 in_model1;
layout(location = 4) in vec4 in_model2;
layout(location = 5) in vec4 in_model3;
layout(location = 6) in vec4 in_color;
layout(location = 7) in vec4 in_params;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_color;
layout(location = 3) out vec4 v_params;
layout(location = 4) out float v_view_depth;

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);

    vec4 world = model * vec4(in_position, 1.0);
    gl_Position = pc.view_proj * world;

    // Blocks are deliberately non-uniformly scaled -- a rifle barrel is long and
    // thin -- so the model matrix alone would skew the normals and light the
    // sides wrong. The inverse transpose is the correct transform, and at two
    // dozen instances its cost does not register.
    mat3 normal_matrix = transpose(inverse(mat3(model)));

    v_world_pos  = world.xyz;
    v_normal     = normalize(normal_matrix * in_normal);
    v_color      = in_color;
    v_params     = in_params;
    v_view_depth = -(frame.view * world).z;
}
