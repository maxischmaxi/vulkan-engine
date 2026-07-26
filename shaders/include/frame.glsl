#ifndef FRAME_GLSL
#define FRAME_GLSL

// Set 0 holds everything that changes once per frame. Every pipeline binds it,
// including the ones that draw no textures at all.
//
// KEEP IN SYNC with Frame_Uniforms in src/frame.odin. The #assert on size and
// offsets there catches the Odin side; nothing catches a mismatch introduced
// here, so change both or neither.

#define SHADOW_CASCADES 3
#define PI 3.14159265359

layout(set = 0, binding = 0) uniform FrameUniforms {
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
    vec4 params; // exposure, point light count, debug mode, shadow texel size in uv
} frame;

struct PointLight {
    vec3  position;
    float radius;
    vec3  color;
    float intensity;
};

layout(std430, set = 0, binding = 1) readonly buffer Lights {
    PointLight lights[];
};

layout(set = 0, binding = 2) uniform sampler2DArrayShadow shadow_maps;

#endif
