#version 450

#include "frame.glsl"

// Imported meshes. Same vertex layout and same fragment shader as the baked
// world -- the only thing a model adds is a per-instance transform, and the only
// thing it loses is the world's guarantee of being lit by every cascade.
//
// The view-projection is a push constant rather than the frame uniform because
// the viewmodel renders through a narrower one (see viewmodel_view_projection).
layout(push_constant) uniform PushConstants {
    mat4 view_proj;
} pc;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_tangent;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in uint in_material;

// per instance
layout(location = 5) in vec4 in_model0;
layout(location = 6) in vec4 in_model1;
layout(location = 7) in vec4 in_model2;
layout(location = 8) in vec4 in_model3;
layout(location = 9) in vec4 in_params; // receives shadow, unused

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_tangent;
layout(location = 3) out vec2 v_uv;
layout(location = 4) out flat uint v_material;
layout(location = 5) out float v_view_depth;
layout(location = 6) out flat float v_receive_shadow;

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);

    vec4 world = model * vec4(in_position, 1.0);
    gl_Position = pc.view_proj * world;

    // Props are fitted to the box they replace, so the scale is per axis and
    // would skew the normals. Every model transform is built from three
    // perpendicular scaled axes, and for a matrix with orthogonal columns the
    // inverse transpose is each column over its own squared length -- exact,
    // and free of the NaN that inverse() produces on a zero extent.
    mat3 m = mat3(model);
    mat3 normal_matrix = mat3(
        m[0] / max(dot(m[0], m[0]), 1e-8),
        m[1] / max(dot(m[1], m[1]), 1e-8),
        m[2] / max(dot(m[2], m[2]), 1e-8)
    );

    v_world_pos = world.xyz;
    v_normal    = normalize(normal_matrix * in_normal);
    // The tangent is a direction along the surface, so it rides the model
    // matrix itself; only the handedness in w carries over untouched.
    v_tangent   = vec4(normalize(m * in_tangent.xyz), in_tangent.w);
    v_uv        = in_uv;
    v_material  = in_material;

    v_view_depth = -(frame.view * world).z;
    v_receive_shadow = in_params.x;
}
