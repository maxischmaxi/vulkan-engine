#version 450

// Untextured blocks through the same lighting model as the textured world, so
// bots and the weapon sit in the scene rather than beside it.

#include "lighting.glsl"
#include "tonemap.glsl"

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_color;
layout(location = 3) in vec4 v_params; // roughness, metallic, emissive, receives shadow
layout(location = 4) in float v_view_depth;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 n = normalize(v_normal);
    vec3 v = normalize(frame.camera_pos.xyz - v_world_pos);

    vec3 albedo = v_color.rgb;
    float roughness = clamp(v_params.x, 0.04, 1.0);
    float metallic = clamp(v_params.y, 0.0, 1.0);
    float emissive = v_params.z;
    bool receive_shadow = v_params.w > 0.5;

    vec3 color = light_surface(
        v_world_pos, n, n, v,
        albedo, roughness, metallic, 1.0,
        v_view_depth, receive_shadow
    );

    // A muzzle flash has to read as a light source, not as a lit surface.
    color += albedo * emissive;

    int mode = int(frame.params.z);
    if (mode == 2) {
        out_color = vec4(albedo, 1.0);
        return;
    } else if (mode == 3) {
        out_color = vec4(n * 0.5 + 0.5, 1.0);
        return;
    }

    out_color = present(color, frame.params.x);
}
