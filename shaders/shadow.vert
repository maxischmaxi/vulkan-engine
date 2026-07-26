#version 450

// Depth-only pass. There is no fragment shader: the depth buffer is the entire
// output, and the rasteriser writes it for free.

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

layout(push_constant) uniform PushConstants {
    uint cascade;
} pc;

layout(location = 0) in vec3 in_position;

void main() {
    // world positions are baked into the buffer, so there is no model matrix
    gl_Position = frame.cascade_vp[pc.cascade] * vec4(in_position, 1.0);
}
