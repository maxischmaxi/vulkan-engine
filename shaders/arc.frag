#version 450

// The white line a wound-up grenade would fly, and the circle where it would
// first touch something.
//
// Alpha rather than additive, unlike the tracers: this is a readout, not light
// in the scene. Additive white over a bright sky washes out to nothing exactly
// where a long throw spends most of its arc.

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_params;

layout(location = 0) out vec4 out_color;

// Dashes per metre of arc, and how much of each one is drawn. A solid line
// reads as a static bar; the gaps give it a direction to be travelling in.
const float DASH_PER_METRE = 3.0;
const float DASH_DUTY = 0.55;

// The first stretch out of the hand is centimetres from the eye and would sit
// as a fat smear across the crosshair. Fading it in over the first metre keeps
// the aim clear without shortening the line anywhere it matters.
const float NEAR_FADE_M = 1.0;

void main() {
    float opacity = v_params.y;

    if (v_params.x > 0.5) {
        // The impact ring, laid on the surface. A bright rim and a faint fill,
        // so it reads on a dark floor and on a light wall alike.
        float r = length(v_local);
        if (r > 1.0) discard;
        float rim = 1.0 - smoothstep(0.06, 0.30, abs(r - 0.78));
        float fill = (1.0 - smoothstep(0.0, 0.78, r)) * 0.12;
        out_color = vec4(vec3(1.0), opacity * clamp(rim + fill, 0.0, 1.0));
        return;
    }

    // Rounded cross-section: full strength along the middle, nothing at the rim.
    float across = 1.0 - v_local.y * v_local.y;

    float dash = fract(v_local.x * DASH_PER_METRE);
    // Soft on both edges of the gap, or the dashes crawl with the sampling.
    float lit = smoothstep(0.0, 0.12, dash) * (1.0 - smoothstep(DASH_DUTY, DASH_DUTY + 0.12, dash));

    float near = smoothstep(0.0, NEAR_FADE_M, v_local.x);

    out_color = vec4(vec3(1.0), opacity * across * lit * near);
}
