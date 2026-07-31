#version 450

// The font atlas is a single-channel signed distance field, 0.5 at the glyph
// edge. Panels and bars ignore it entirely and take their alpha straight from
// the vertex colour.
layout(set = 0, binding = 0) uniform sampler2D glyph_atlas;

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec2 v_local;
layout(location = 3) in vec3 v_shape;
layout(location = 4) in float v_mode;
layout(location = 5) in float v_edge_bias;

layout(location = 0) out vec4 out_color;

// Negative inside the box, positive outside, measured in pixels.
float rounded_box(vec2 p, vec2 half_size, float radius) {
    vec2 d = abs(p) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main() {
    float alpha = v_color.a;

    if (v_mode > 1.5) {
        // horizontal fade: full colour at the left edge, gone at the right.
        // The menu's backdrop scrim; smoothstep keeps the tail from banding.
        alpha *= 1.0 - smoothstep(0.0, 1.0, v_uv.x);
    } else if (v_mode > 0.5) {
        // fwidth keeps the edge exactly one screen pixel soft at every size; a
        // positive bias moves the threshold outward, fattening the glyph.
        float d = texture(glyph_atlas, v_uv).r;
        float w = max(fwidth(d), 0.004);
        alpha *= smoothstep(0.5 - w - v_edge_bias, 0.5 + w - v_edge_bias, d);
    }

    // MSAA only antialiases geometric edges, and the corners of a rounded panel
    // are not one -- they are inside the quad. The distance field is what makes
    // them smooth, and one pixel of falloff is enough at any HUD size.
    if (v_shape.z > 0.0) {
        alpha *= clamp(0.5 - rounded_box(v_local, v_shape.xy, v_shape.z), 0.0, 1.0);
    }

    if (alpha <= 0.002) discard;

    // Written in display space, like the crosshair: the swapchain is sRGB, so
    // the hardware does the encode and the HUD must not be tonemapped.
    out_color = vec4(v_color.rgb, alpha);
}
