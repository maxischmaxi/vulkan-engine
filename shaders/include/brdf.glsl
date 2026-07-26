#ifndef BRDF_GLSL
#define BRDF_GLSL

#include "frame.glsl"

// Cook-Torrance with a metallic/roughness workflow -- the same model glTF,
// Unreal and Unity HDRP use, so authored maps behave the way they were meant to.

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

// Every point light in the buffer. Inverse square with the UE4 windowing term,
// so a light reaches exactly zero at its radius instead of trailing off forever
// and costing the whole screen.
vec3 point_lights_contribution(
    vec3 world_pos, vec3 n, vec3 v, vec3 albedo, float metallic, float alpha
) {
    vec3 sum = vec3(0.0);
    int count = int(frame.params.y);

    for (int i = 0; i < count; i++) {
        vec3 to_light = lights[i].position - world_pos;
        float dist2 = dot(to_light, to_light);
        float dist = sqrt(dist2);
        if (dist >= lights[i].radius) continue;

        float falloff = clamp(1.0 - pow(dist / lights[i].radius, 4.0), 0.0, 1.0);
        float attenuation = falloff * falloff / max(dist2, 1e-4);

        vec3 radiance = lights[i].color * lights[i].intensity * attenuation;
        sum += shade(n, v, to_light / dist, radiance, albedo, metallic, alpha);
    }
    return sum;
}

// Hemisphere fill standing in for bounced light: sky from above, warm bounce
// from the ground below. Far cheaper than an irradiance probe and enough to keep
// shadowed surfaces from going flat black.
vec3 ambient_contribution(vec3 n, vec3 albedo, float occlusion, float metallic) {
    float hemi = n.z * 0.5 + 0.5;
    vec3 ambient = mix(frame.ambient_ground.rgb, frame.ambient_sky.rgb, hemi);
    return ambient * albedo * occlusion * (1.0 - metallic);
}

#endif
