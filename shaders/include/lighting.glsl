#ifndef LIGHTING_GLSL
#define LIGHTING_GLSL

#include "brdf.glsl"
#include "shadow.glsl"

// The complete lighting model for one surface point: shadowed sun, every point
// light, hemisphere ambient. Both the textured world and the untextured blocks
// go through here, which is what keeps props sitting in the scene rather than
// beside it.
//
// n is the shading normal (normal-mapped where there is a map), n_geom the
// geometric one -- the shadow lookup needs the geometry, not the detail.
vec3 light_surface(
    vec3  world_pos,
    vec3  n,
    vec3  n_geom,
    vec3  v,
    vec3  albedo,
    float roughness,
    float metallic,
    float occlusion,
    float view_depth,
    bool  receive_shadow
) {
    // perceptual roughness squared is what the BRDF actually wants
    float alpha = roughness * roughness;
    vec3 color = vec3(0.0);

    vec3 l = -normalize(frame.sun_direction.xyz);
    float n_dot_l = dot(n, l);
    if (n_dot_l > 0.0) {
        float shadow = receive_shadow
            ? sun_shadow(world_pos, n_geom, dot(n_geom, l), view_depth)
            : 1.0;
        color += shade(n, v, l, frame.sun_color.rgb * shadow, albedo, metallic, alpha);
    }

    color += point_lights_contribution(world_pos, n, v, albedo, metallic, alpha);
    color += ambient_contribution(n, albedo, occlusion, metallic);

    return color;
}

#endif
