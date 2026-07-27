#ifndef SHADOW_GLSL
#define SHADOW_GLSL

#include "frame.glsl"

int pick_cascade(float view_depth) {
    for (int i = 0; i < SHADOW_CASCADES; i++) {
        if (view_depth < frame.cascade_splits[i]) return i;
    }
    return SHADOW_CASCADES; // past the shadow distance
}

// Hardware comparison fetches, in a kernel whose width is a setting. Each fetch
// is already bilinear, so even the single-tap case is a 2x2 filter and reads as
// soft rather than as a hard edge -- which is why turning this down costs less
// than it sounds like.
//
// The cascade_vp index is clamped: the array is sized to the maximum, and a
// dynamic index past the active count would read a matrix nobody wrote.
float sample_cascade(int cascade, vec3 world_pos) {
    vec4 light_space = frame.cascade_vp[min(cascade, SHADOW_CASCADES_MAX - 1)] * vec4(world_pos, 1.0);
    vec3 proj = light_space.xyz / light_space.w;

    // outside the light's depth range: nothing there can be occluding it
    if (proj.z > 1.0 || proj.z < 0.0) return 1.0;

    vec2 uv = proj.xy * 0.5 + 0.5;
    float texel = frame.params.w;

    if (SHADOW_PCF <= 1) {
        return texture(shadow_maps, vec4(uv, float(cascade), proj.z));
    }

    // 4 taps on a rotated diagonal cover about as much ground as the full box
    // for less than half the fetches, which is why this is the middle rung.
    float sum = 0.0;
    if (SHADOW_PCF <= 4) {
        const vec2 taps[4] = vec2[4](vec2(-0.7, -0.7), vec2(0.7, -0.7),
                                     vec2(-0.7, 0.7), vec2(0.7, 0.7));
        for (int i = 0; i < 4; i++) {
            sum += texture(shadow_maps, vec4(uv + taps[i] * texel, float(cascade), proj.z));
        }
        return sum * 0.25;
    }

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(float(x), float(y)) * texel;
            sum += texture(shadow_maps, vec4(uv + offset, float(cascade), proj.z));
        }
    }
    return sum / 9.0;
}

// Offsetting the lookup along the surface normal rather than only biasing depth
// is what keeps steep surfaces free of acne without detaching shadows from their
// casters. The offset scales with the cascade's texel size in metres.
//
// Pass the geometric normal, not the mapped one: the shadow map knows nothing
// about normal map detail.
float sun_shadow(vec3 world_pos, vec3 n, float n_dot_l, float view_depth) {
    int cascade = pick_cascade(view_depth);
    if (cascade >= SHADOW_CASCADES) return 1.0;

    float slope = clamp(1.0 - n_dot_l, 0.0, 1.0);
    vec3 offset_pos = world_pos + n * frame.cascade_texel[cascade] * (1.0 + 3.0 * slope) * 1.5;

    float shadow = sample_cascade(cascade, offset_pos);

    // Fade into the next cascade over the last stretch of this one, otherwise
    // the resolution change shows up as a hard line across the ground.
    float split_end = frame.cascade_splits[cascade];
    float split_start = cascade == 0 ? 0.0 : frame.cascade_splits[cascade - 1];
    float band = (split_end - split_start) * 0.15;
    float blend = clamp((view_depth - (split_end - band)) / max(band, 1e-4), 0.0, 1.0);

    if (blend > 0.0 && cascade + 1 < SHADOW_CASCADES) {
        vec3 next_offset = world_pos + n * frame.cascade_texel[cascade + 1] * (1.0 + 3.0 * slope) * 1.5;
        shadow = mix(shadow, sample_cascade(cascade + 1, next_offset), blend);
    }
    return shadow;
}

#endif
