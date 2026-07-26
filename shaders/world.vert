#version 450

#define SHADOW_CASCADES 3

layout(binding = 0) uniform FrameUniforms {
    mat4 view;
    mat4 proj;
    mat4 view_proj;
    mat4 cascade_vp[SHADOW_CASCADES];
    vec4 cascade_splits;
    vec4 cascade_texel;
    vec4 camera_pos;
    vec4 sun_direction;
    vec4 sun_color;
    vec4 ambient_sky;
    vec4 ambient_ground;
    vec4 params;
} frame;

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_tangent;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in uint in_material;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_tangent;
layout(location = 3) out vec2 v_uv;
layout(location = 4) out flat uint v_material;
layout(location = 5) out float v_view_depth;

void main() {
    vec4 world = vec4(in_position, 1.0);
    gl_Position = frame.view_proj * world;

    v_world_pos = in_position;
    v_normal    = in_normal;
    v_tangent   = in_tangent;
    // uv arrives in metres; the fragment shader divides by the material's scale
    v_uv        = in_uv;
    v_material  = in_material;

    // distance along the view axis, which is what selects the shadow cascade
    v_view_depth = -(frame.view * world).z;
}
