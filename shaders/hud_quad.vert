#version 450

// One instance is one rectangle in screen pixels, origin top left. Everything
// the HUD draws -- panels, bars, glyphs, the minimap and its markers -- is one
// of these, so the whole overlay is a single instanced draw per scissor region.

layout(push_constant) uniform PushConstants {
    vec4 screen; // 1/width, 1/height, unused, unused
} pc;

layout(location = 0) in vec4 i_rect;   // x, y, width, height in pixels
layout(location = 1) in vec4 i_uv;     // u0, v0, u1, v1 in the glyph atlas
layout(location = 2) in vec4 i_color;
layout(location = 3) in vec4 i_params; // rotation (radians), mode, corner radius (px), edge bias

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec2 v_local; // pixels from the rectangle's centre
layout(location = 3) out vec3 v_shape; // half width, half height, corner radius
layout(location = 4) out float v_mode;
layout(location = 5) out float v_edge_bias; // SDF threshold shift; text shadows fatten with it

const vec2 QUAD[6] = vec2[6](
    vec2(0, 0), vec2(1, 0), vec2(1, 1),
    vec2(0, 0), vec2(1, 1), vec2(0, 1)
);

void main() {
    vec2 q = QUAD[gl_VertexIndex];
    vec2 half_size = i_rect.zw * 0.5;
    vec2 local = (q - 0.5) * i_rect.zw;

    // Rotation is about the rectangle's own centre. Vulkan's y grows downward,
    // so a positive angle turns clockwise on screen.
    float c = cos(i_params.x);
    float s = sin(i_params.x);
    vec2 turned = vec2(local.x * c - local.y * s, local.x * s + local.y * c);

    // z = 1 is the near plane under the reversed-Z the world renders with. The
    // HUD pipeline has depth testing off so nothing reads it today, but a 0 here
    // would sit at the far plane and vanish the day it is switched on.
    vec2 pixel = i_rect.xy + half_size + turned;
    gl_Position = vec4(pixel * pc.screen.xy * 2.0 - 1.0, 1.0, 1.0);

    v_color = i_color;
    v_uv = mix(i_uv.xy, i_uv.zw, q);
    // The unrotated offset: the rounded-corner test is done in the rectangle's
    // own frame, so it does not have to undo the rotation.
    v_local = local;
    v_shape = vec3(half_size, i_params.z);
    v_mode = i_params.y;
    v_edge_bias = i_params.w;
}
