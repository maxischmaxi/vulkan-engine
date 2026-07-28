#ifndef FRAME_GLSL
#define FRAME_GLSL

// Set 0 holds everything that changes once per frame. Every pipeline binds it,
// including the ones that draw no textures at all.
//
// KEEP IN SYNC with Frame_Uniforms in src/frame.odin. The #assert on size and
// offsets there catches the Odin side; nothing catches a mismatch introduced
// here, so change both or neither.

// The most cascades the uniform block can carry. Fixed, because the block's
// layout is, and unused slots cost nothing.
#define SHADOW_CASCADES_MAX 3
#define PI 3.14159265359

// How many are actually in use, and how wide the percentage-closer filter is.
// Both are specialization constants, so the loops below unroll to whatever the
// current settings chose and a cascade count of zero deletes the shadow lookup
// entirely rather than branching around it.
//
// KEEP IN SYNC with Spec_Shadow_Cascades / Spec_Shadow_Pcf in src/shadow.odin.
layout(constant_id = 0) const int SHADOW_CASCADES = 3;
layout(constant_id = 1) const int SHADOW_PCF = 9;

layout(set = 0, binding = 0) uniform FrameUniforms {
    mat4 view;
    mat4 proj;
    mat4 view_proj;
    mat4 cascade_vp[SHADOW_CASCADES_MAX];
    vec4 cascade_splits;
    vec4 cascade_texel;
    vec4 camera_pos;
    vec4 sun_direction;
    vec4 sun_color;
    vec4 ambient_sky;
    vec4 ambient_ground;
    vec4 params; // exposure, point light count, debug mode, shadow texel size in uv
    uvec4 light_grid; // tiles across, log2 of tile size in pixels, 0, 0
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

// One 64-bit mask per screen tile: bit i set means light i can reach the tile.
// Written by the CPU every frame (src/light_tiles.odin); with culling off every
// bit up to the light count is set, so the shader path never changes shape.
layout(std430, set = 0, binding = 3) readonly buffer LightTiles {
    uvec2 light_tiles[];
};

uvec2 tile_light_mask(vec2 frag_coord) {
    uvec2 tile = uvec2(frag_coord) >> frame.light_grid.y;
    return light_tiles[tile.y * frame.light_grid.x + tile.x];
}

#endif
