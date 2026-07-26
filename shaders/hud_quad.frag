#version 450

// The font atlas is single-channel coverage. Panels and bars ignore it entirely
// and take their alpha straight from the vertex colour.
layout(set = 0, binding = 0) uniform sampler2D glyph_atlas;

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec2 v_local;
layout(location = 3) in vec3 v_shape;
layout(location = 4) in float v_mode;

layout(location = 0) out vec4 out_color;

// Negative inside the box, positive outside, measured in pixels.
float rounded_box(vec2 p, vec2 half_size, float radius) {
    vec2 d = abs(p) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main() {
    float alpha = v_color.a;

    if (v_mode > 0.5) {
        alpha *= texture(glyph_atlas, v_uv).r;
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
