#version 450

// The hole is generated rather than sampled: no texture to author, no extra
// sampler binding, and a bullet hole is simple enough that a texture would only
// add memory traffic.
//
// It is drawn unlit on purpose. A hole is a hole no matter how brightly the wall
// around it is lit -- shading it would make it glow in sunlight.

#include "frame.glsl"
#include "tonemap.glsl"

layout(location = 0) in vec2 v_local;
layout(location = 1) in float v_seed;
layout(location = 2) in float v_kind;

layout(location = 0) out vec4 out_color;

// KEEP IN SYNC with Decal_Kind in src/decal_render.odin.
#define KIND_SCORCH 1.0

// Cheap angular noise so no two holes have the same silhouette.
float edge_wobble(vec2 p, float seed) {
    float angle = atan(p.y, p.x);
    return sin(angle * 5.0 + seed * 21.7) * 0.06 + sin(angle * 11.0 + seed * 7.3) * 0.03;
}

void main() {
    float r = length(v_local);
    if (r > 1.0) discard;

    float wobble = edge_wobble(v_local, v_seed);

    if (v_kind > KIND_SCORCH - 0.5) {
        // A blast leaves soot, not a hole: no core, no rim, just a smudge that
        // is darkest in the middle and gone before the quad's edge.
        //
        // The wobble stays at the bullet hole's amplitude here, and only
        // displaces the outer edge. Driving it harder was tried and turned the
        // mark into a five-pointed star -- the lobes of sin(angle * 5) become
        // the whole silhouette once the falloff has nothing else to say.
        float soot = 1.0 - smoothstep(0.12, 0.95 + wobble, r);
        soot = pow(soot, 1.5);
        if (soot < 0.01) discard;
        out_color = vec4(tonemap_aces(vec3(0.05, 0.043, 0.038) * frame.params.x), soot * 0.66);
        return;
    }

    // Dark core, then a ring of pulverised material, fading to nothing. The core
    // has to hold a good share of the quad or the light rim swallows it and the
    // whole thing reads as a bright speck instead of a hole.
    float core = 1.0 - smoothstep(0.12, 0.46 + wobble, r);

    // The dust ring is deliberately barely there. Alpha blending accumulates:
    // twelve overlapping rims at 0.3 alpha cover the wall completely, so a burst
    // fired at one spot turns into a single pale blob. The dark core carries the
    // shape; the ring only softens its edge.
    float dust = (1.0 - smoothstep(0.38 + wobble, 0.92 + wobble, r)) * 0.14;

    float alpha = clamp(core + dust, 0.0, 1.0);
    if (alpha < 0.01) discard;

    // The rim is lighter than the hole itself, which is what makes it read as
    // depth rather than as a sticker -- but darker than the wall, so overlapping
    // holes deepen the mark instead of brightening the surface.
    vec3 color = mix(vec3(0.16, 0.14, 0.12), vec3(0.02, 0.018, 0.015), core);

    // Everything else in the frame lands in the buffer tonemapped. Writing raw
    // linear values here would make the decal sit visibly brighter than the
    // surface it is drawn on.
    out_color = vec4(tonemap_aces(color * frame.params.x), alpha);
}
