#version 450

#include "frame.glsl"
#include "noise.glsl"
#include "tonemap.glsl"

// Particles, without a single texture. The volumetric smoke next to them is
// made of the same value noise (noise.glsl), so a puff at the edge of a cloud
// and the cloud itself are literally the same field sampled two ways -- which
// is what keeps the edge of a smoke from reading as two different materials
// meeting.

// KEEP IN SYNC with Particle_Look in src/particles.odin.
#define LOOK_SOFT 0.0
#define LOOK_FIRE 1.0
#define LOOK_SPARK 2.0

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec4 v_color;
layout(location = 2) in vec4 v_params; // look, seed, age 0..1, stretch
layout(location = 3) in vec3 v_world;

layout(location = 0) out vec4 out_color;

void main() {
    float r = length(v_local);
    if (r > 1.0) discard;

    float look = v_params.x;
    float seed = v_params.y;
    float age = v_params.z;

    if (look < LOOK_FIRE - 0.5) {
        // Smoke and dust: a soft disc eaten into by noise, so the silhouette
        // frays instead of being a circle. The field drifts with age, which is
        // what makes a puff churn while it expands rather than just scaling.
        float mask = 1.0 - smoothstep(0.15, 1.0, r);
        float n = fbm(v_world * 1.7 + vec3(seed * 37.0, seed * 11.0, age * 0.9));
        mask *= 0.45 + 0.85 * n;
        out_color = vec4(v_color.rgb, clamp(mask, 0.0, 1.0) * v_color.a);
        return;
    }

    if (look < LOOK_SPARK - 0.5) {
        // Fire: a hot core falling off fast. Driven past 1.0 before the curve
        // like the tracers, because the buffer holds tonemapped values and every
        // emitter has to bring its own.
        //
        // The drive is deliberately modest for something meant to look hot. A
        // fireball is a dozen of these overlapping, and ADDITIVE blending sums
        // them: at a drive that looked right for one particle the pile came out
        // a flat white disc with no orange anywhere in it. The colour has to
        // survive the stack, not the single quad.
        float core = 1.0 - smoothstep(0.0, 0.8, r);
        core *= core;
        float n = 0.6 + 0.8 * fbm(v_world * 2.4 + vec3(seed * 23.0, age * 2.1, seed * 5.0));
        vec3 hdr = v_color.rgb * (0.95 * frame.params.x) * core * n;
        out_color = vec4(tonemap_aces(hdr) * v_color.a, 1.0);
        return;
    }

    // Spark: bright the whole way along, out at the tips. Already stretched by
    // the vertex shader, so this only has to shape the cross-section.
    float across = 1.0 - v_local.x * v_local.x;
    float along = 1.0 - smoothstep(0.4, 1.0, abs(v_local.y));
    vec3 hdr = v_color.rgb * (1.7 * frame.params.x) * across * along;
    out_color = vec4(tonemap_aces(hdr) * v_color.a, 1.0);
}
