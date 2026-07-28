#version 450

// A glowing dash: a hot core fading toward the edges and the tail. Additive,
// because a tracer is light over the scene -- overlapping streaks should
// brighten each other, not paint over each other.

#include "frame.glsl"
#include "tonemap.glsl"

layout(location = 0) in vec2 v_local;

layout(location = 0) out vec4 out_color;

void main() {
    // Rounded cross-section: full strength along the middle, nothing at the rim.
    float across = 1.0 - v_local.y * v_local.y;
    // The tail hangs on at a third so the streak reads as a dash, not a point;
    // the head stays the bright end that is the bullet.
    float glow = across * mix(0.3, 1.0, v_local.x);

    // Driven past 1.0 before the curve, so the core saturates toward white the
    // way every other bright emitter in the scene does. The buffer holds
    // tonemapped values, so the contribution is scaled after the curve.
    vec3 color = tonemap_aces(vec3(1.0, 0.83, 0.45) * (2.0 * frame.params.x));
    out_color = vec4(color * glow, 1.0);
}
