#version 450

// The textured map. Everything about the lighting model itself lives in the
// shared includes -- this file is only about turning texture arrays into surface
// parameters.

#include "lighting.glsl"
#include "tonemap.glsl"

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

// Set 1 is the static material data: it never changes after load, so it is bound
// once rather than per frame.
layout(std430, set = 1, binding = 0) readonly buffer Materials {
    Material materials[];
};

layout(set = 1, binding = 1) uniform sampler2DArray albedo_maps;
layout(set = 1, binding = 2) uniform sampler2DArray normal_maps;
layout(set = 1, binding = 3) uniform sampler2DArray orm_maps; // r=occlusion g=roughness b=metallic

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_tangent;
layout(location = 3) in vec2 v_uv;
layout(location = 4) in flat uint v_material;
layout(location = 5) in float v_view_depth;

layout(location = 0) out vec4 out_color;

void main() {
    Material m = materials[v_material];
    vec2 uv = v_uv / m.uv_scale;
    vec3 layer_uv = vec3(uv, float(m.layer));

    // Desaturate toward the texture's own luminance, then tint. Doing it in this
    // order is what lets ten unrelated source textures read as one material
    // palette instead of ten separate ones.
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

    // Checked before the lighting, not after. These two views throw the lit
    // colour away, and running the full PBR plus a cascade lookup to discard it
    // made the debug views the slowest thing in the build -- on exactly the
    // hardware they exist to diagnose.
    int mode = int(frame.params.z);
    if (mode == 2) {
        out_color = vec4(albedo, 1.0);
        return;
    }
    if (mode == 3) {
        out_color = vec4(n * 0.5 + 0.5, 1.0);
        return;
    }

    vec3 color = light_surface(
        v_world_pos, n, n_geom, v,
        albedo, roughness, metallic, occlusion,
        v_view_depth, true
    );

    if (mode == 1) {
        int cascade = pick_cascade(v_view_depth);
        vec3 tint = vec3(0.4);
        if (cascade == 0) tint = vec3(1.0, 0.3, 0.3);
        else if (cascade == 1) tint = vec3(0.3, 1.0, 0.3);
        else if (cascade == 2) tint = vec3(0.3, 0.3, 1.0);
        color *= tint;
    } else if (mode == 4) {
        // same lighting with a neutral surface, to judge light placement
        color /= max(albedo, vec3(1e-3));
        color *= 0.5;
    }

    out_color = present(color, frame.params.x);
}
