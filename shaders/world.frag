#version 450

// Cook-Torrance PBR with a metallic/roughness workflow -- the same model glTF,
// Unreal and Unity HDRP use, so the ambientCG maps behave the way they were
// authored to. One shadowed directional light plus a loop over point lights.

#define SHADOW_CASCADES 3
#define PI 3.14159265359

layout(binding = 0) uniform FrameUniforms {
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

layout(std430, binding = 1) readonly buffer Lights {
    PointLight lights[];
};

struct Material {
    vec4  tint;
    uint  layer;
    float uv_scale;
    float roughness_mul;
    float metallic;
    float normal_scale;
    float saturation;
    float _pad0;
    float _pad1;
};

layout(std430, binding = 2) readonly buffer Materials {
    Material materials[];
};

layout(binding = 3) uniform sampler2DArray albedo_maps;
layout(binding = 4) uniform sampler2DArray normal_maps;
layout(binding = 5) uniform sampler2DArray orm_maps; // r=occlusion g=roughness b=metallic
layout(binding = 6) uniform sampler2DArrayShadow shadow_maps;

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv;
layout(location = 4) in flat uint v_material;
layout(location = 5) in float v_view_depth;

layout(location = 0) out vec4 out_color;

// ---------------------------------------------------------------------- BRDF

// GGX / Trowbridge-Reitz: how much of the microsurface is oriented to reflect
// straight from the light to the eye.
float distribution_ggx(float n_dot_h, float alpha) {
    float a2 = alpha * alpha;
    float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 1e-7);
}

// Height-correlated Smith visibility, which already folds in the 1/(4 NoL NoV)
// denominator of the specular term.
float visibility_smith(float n_dot_v, float n_dot_l, float alpha) {
    float a2 = alpha * alpha;
    float lv = n_dot_l * sqrt(n_dot_v * n_dot_v * (1.0 - a2) + a2);
    float ll = n_dot_v * sqrt(n_dot_l * n_dot_l * (1.0 - a2) + a2);
    return 0.5 / max(lv + ll, 1e-5);
}

vec3 fresnel_schlick(vec3 f0, float v_dot_h) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - v_dot_h, 0.0, 1.0), 5.0);
}

// Radiance from one light, given the surface parameters.
vec3 shade(vec3 n, vec3 v, vec3 l, vec3 radiance, vec3 albedo, float metallic, float alpha) {
    float n_dot_l = dot(n, l);
    if (n_dot_l <= 0.0) return vec3(0.0);

    vec3 h = normalize(v + l);
    float n_dot_v = max(dot(n, v), 1e-4);
    float n_dot_h = max(dot(n, h), 0.0);
    float v_dot_h = max(dot(v, h), 0.0);

    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    vec3 f = fresnel_schlick(f0, v_dot_h);

    vec3 specular = distribution_ggx(n_dot_h, alpha) * visibility_smith(n_dot_v, n_dot_l, alpha) * f;

    // What is not reflected is available to scatter diffusely, and metals
    // scatter nothing.
    vec3 diffuse = (1.0 - f) * (1.0 - metallic) * albedo / PI;

    return (diffuse + specular) * radiance * n_dot_l;
}

// -------------------------------------------------------------------- shadows

int pick_cascade(float depth) {
    for (int i = 0; i < SHADOW_CASCADES; i++) {
        if (depth < frame.cascade_splits[i]) return i;
    }
    return SHADOW_CASCADES; // past the shadow distance
}

// 3x3 kernel of hardware comparison fetches. Each fetch is already bilinear, so
// nine taps cover roughly a 4x4 texel neighbourhood.
float sample_cascade(int cascade, vec3 world_pos) {
    vec4 light_space = frame.cascade_vp[cascade] * vec4(world_pos, 1.0);
    vec3 proj = light_space.xyz / light_space.w;

    // behind the light's far plane: nothing can be occluding it
    if (proj.z > 1.0 || proj.z < 0.0) return 1.0;

    vec2 uv = proj.xy * 0.5 + 0.5;
    float texel = frame.params.w;

    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(float(x), float(y)) * texel;
            sum += texture(shadow_maps, vec4(uv + offset, float(cascade), proj.z));
        }
    }
    return sum / 9.0;
}

// Offsetting the lookup along the surface normal rather than only biasing depth
// is what keeps steep surfaces free of acne without detaching shadows from
// their casters. The offset scales with the cascade's texel size in metres.
float sun_shadow(vec3 world_pos, vec3 n, float n_dot_l) {
    int cascade = pick_cascade(v_view_depth);
    if (cascade >= SHADOW_CASCADES) return 1.0;

    float slope = clamp(1.0 - n_dot_l, 0.0, 1.0);
    vec3 offset_pos = world_pos + n * frame.cascade_texel[cascade] * (1.0 + 3.0 * slope) * 1.5;

    float shadow = sample_cascade(cascade, offset_pos);

    // Fade into the next cascade over the last stretch of this one, otherwise
    // the resolution change shows up as a hard line across the ground.
    float split_end = frame.cascade_splits[cascade];
    float split_start = cascade == 0 ? 0.0 : frame.cascade_splits[cascade - 1];
    float band = (split_end - split_start) * 0.15;
    float blend = clamp((v_view_depth - (split_end - band)) / max(band, 1e-4), 0.0, 1.0);

    if (blend > 0.0 && cascade + 1 < SHADOW_CASCADES) {
        vec3 next_offset = world_pos + n * frame.cascade_texel[cascade + 1] * (1.0 + 3.0 * slope) * 1.5;
        shadow = mix(shadow, sample_cascade(cascade + 1, next_offset), blend);
    }
    return shadow;
}

// ------------------------------------------------------------------ tonemap

// ACES filmic approximation by Krzysztof Narkowicz. Compresses the highlights
// so a bright sun does not clip to flat white.
vec3 tonemap_aces(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    Material m = materials[v_material];
    vec2 uv = v_uv / m.uv_scale;
    vec3 layer_uv = vec3(uv, float(m.layer));

    // Desaturate toward the texture's own luminance, then tint. Doing it in
    // this order is what lets ten unrelated source textures read as one
    // material palette instead of ten separate ones.
    vec3 albedo = texture(albedo_maps, layer_uv).rgb;
    float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
    albedo = mix(vec3(luma), albedo, m.saturation) * m.tint.rgb;

    vec3 orm = texture(orm_maps, layer_uv).rgb;
    float occlusion = orm.r;
    float roughness = clamp(orm.g * m.roughness_mul, 0.04, 1.0);
    float metallic = clamp(m.metallic, 0.0, 1.0);

    // Tangent basis. The bitangent follows the glTF rule, and the green channel
    // is flipped because ambientCG ships OpenGL-convention maps where +G points
    // up the image while our v axis runs down it.
    vec3 n_geom = normalize(v_normal);
    vec3 t = normalize(v_tangent.xyz);
    vec3 b = cross(n_geom, t) * v_tangent.w;

    vec3 n_ts = texture(normal_maps, layer_uv).xyz * 2.0 - 1.0;
    n_ts.y = -n_ts.y;
    n_ts.xy *= m.normal_scale;

    vec3 n = normalize(mat3(t, b, n_geom) * n_ts);
    vec3 v = normalize(frame.camera_pos.xyz - v_world_pos);

    // Perceptual roughness squared is what the BRDF actually wants.
    float alpha = roughness * roughness;

    vec3 color = vec3(0.0);

    // ------------------------------------------------------------------ sun
    vec3 l = -normalize(frame.sun_direction.xyz);
    float n_dot_l = dot(n, l);
    if (n_dot_l > 0.0) {
        // shadowing is tested against the geometric normal: the normal map adds
        // detail that the shadow map has no knowledge of
        float shadow = sun_shadow(v_world_pos, n_geom, dot(n_geom, l));
        color += shade(n, v, l, frame.sun_color.rgb * shadow, albedo, metallic, alpha);
    }

    // ---------------------------------------------------------- point lights
    int light_count = int(frame.params.y);
    for (int i = 0; i < light_count; i++) {
        vec3 to_light = lights[i].position - v_world_pos;
        float dist2 = dot(to_light, to_light);
        float dist = sqrt(dist2);
        if (dist >= lights[i].radius) continue;

        // Inverse square with the UE4 windowing term, so the contribution
        // reaches exactly zero at the radius instead of trailing off forever.
        float falloff = clamp(1.0 - pow(dist / lights[i].radius, 4.0), 0.0, 1.0);
        float attenuation = falloff * falloff / max(dist2, 1e-4);

        vec3 radiance = lights[i].color * lights[i].intensity * attenuation;
        color += shade(n, v, to_light / dist, radiance, albedo, metallic, alpha);
    }

    // --------------------------------------------------------------- ambient
    // Hemisphere fill: sky from above, warm bounce from the ground below.
    float hemi = n.z * 0.5 + 0.5;
    vec3 ambient = mix(frame.ambient_ground.rgb, frame.ambient_sky.rgb, hemi);
    color += ambient * albedo * occlusion * (1.0 - metallic);

    // ----------------------------------------------------------------- debug
    int mode = int(frame.params.z);
    if (mode == 1) {
        int cascade = pick_cascade(v_view_depth);
        vec3 tint = vec3(0.4);
        if (cascade == 0) tint = vec3(1.0, 0.3, 0.3);
        else if (cascade == 1) tint = vec3(0.3, 1.0, 0.3);
        else if (cascade == 2) tint = vec3(0.3, 0.3, 1.0);
        color *= tint;
    } else if (mode == 2) {
        out_color = vec4(albedo, 1.0);
        return;
    } else if (mode == 3) {
        out_color = vec4(n * 0.5 + 0.5, 1.0);
        return;
    } else if (mode == 4) {
        // same lighting with a neutral surface, to judge light placement
        color /= max(albedo, vec3(1e-3));
        color *= 0.5;
    }

    // The swapchain is an _SRGB format, so the hardware applies the transfer
    // curve on write. Doing it here as well would wash the image out.
    out_color = vec4(tonemap_aces(color * frame.params.x), 1.0);
}
