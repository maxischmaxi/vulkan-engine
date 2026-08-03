#version 450

#include "frame.glsl"
#include "noise.glsl"

// Volumetric smoke: march the ray from the eye through the cloud, accumulate
// density, stop at whatever the opaque pass already drew.
//
// The density field is value noise over three octaves, drifting slowly so the
// cloud churns rather than sitting there as a textured ball. What matters for
// gameplay is not this shader at all -- the sight blocking is decided on the
// CPU by game/zone.odin, on both ends of the wire -- so nothing here has to
// agree with anything except the eye.

// Steps along the ray. A specialization constant so the graphics presets can
// pick it: this is pure fragment throughput, which is exactly what a weak GPU
// has least of.
layout(constant_id = 2) const int SMOKE_STEPS = 24;

layout(location = 0) in vec3 v_world;
layout(location = 1) in vec4 v_sphere;
layout(location = 2) in vec4 v_params;

layout(location = 0) out vec4 out_color;

// Density at a point: a soft-edged sphere, eaten into by noise. Falls to zero
// at the rim so the cloud has no hard silhouette.
float density_at(vec3 p, vec4 sphere, float seed) {
    vec3 offset = p - sphere.xyz;
    float d = length(offset) / max(sphere.w, 0.001);
    if (d >= 1.0) return 0.0;

    // Squared falloff, and a flat core: the middle of a smoke is opaque, the
    // outside fades.
    float shell = 1.0 - d * d;
    shell = shell * shell;

    // The drift is what makes it look alive. Slow -- a cloud that boils reads
    // as fire, not smoke.
    vec3 q = p * 0.55 + vec3(0.0, 0.0, seed);
    float n = fbm(q);

    return clamp(shell * (n * 1.5 + 0.35), 0.0, 1.0);
}

// Entry and exit distances of a ray through a sphere. x >= y means a miss.
vec2 sphere_span(vec3 origin, vec3 dir, vec4 sphere) {
    vec3 m = origin - sphere.xyz;
    float b = dot(m, dir);
    float c = dot(m, m) - sphere.w * sphere.w;
    float disc = b * b - c;
    if (disc <= 0.0) return vec2(1.0, 0.0);
    float root = sqrt(disc);
    return vec2(-b - root, -b + root);
}

// Distance from the eye to whatever the opaque pass drew at this pixel.
// Reversed-Z with an infinite far plane, so the depth value maps back as
// near / depth; a depth of zero is the far plane and means nothing was drawn.
float scene_distance(vec2 frag_coord, vec3 ray_dir) {
    vec2 uv = frag_coord / vec2(textureSize(scene_depth, 0));
    float depth = texture(scene_depth, uv).r;
    if (depth <= 0.0) return 1e9;

    // View-space z from the projection: proj[3][2] is the near plane under the
    // reversed-Z convention this engine uses.
    float view_z = frame.proj[3][2] / depth;

    // The ray is not the view axis, so the distance along it is longer than
    // the depth by the cosine between them.
    vec3 forward = -vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]);
    float cosine = max(dot(ray_dir, forward), 1e-4);
    return view_z / cosine;
}

void main() {
    vec3 eye = frame.camera_pos.xyz;
    vec3 ray = normalize(v_world - eye);

    vec2 span = sphere_span(eye, ray, v_sphere);
    if (span.x >= span.y) discard;

    // Never start behind the eye: inside the cloud the entry point is negative
    // and the march has to begin at the camera itself.
    float t0 = max(span.x, 0.0);
    float t1 = min(span.y, scene_distance(gl_FragCoord.xy, ray));
    if (t1 <= t0) discard;

    float step_size = (t1 - t0) / float(SMOKE_STEPS);

    // Dither the start by a per-pixel hash. Without it, the fixed step count
    // draws concentric shells through the cloud -- the classic banding of every
    // undersampled volume.
    float jitter = hash13(vec3(gl_FragCoord.xy, v_params.y)) * step_size;

    float transmittance = 1.0;
    vec3 scattered = vec3(0.0);

    // Sunlight through the cloud, without a second march: brighter where the
    // ray enters facing the sun, so the cloud has a lit side.
    vec3 sun = normalize(-frame.sun_direction.xyz);
    float sun_facing = max(dot(ray, sun), 0.0);
    vec3 lit = frame.ambient_sky.rgb + frame.sun_color.rgb * (0.25 + 0.55 * sun_facing);

    for (int i = 0; i < SMOKE_STEPS; ++i) {
        float t = t0 + jitter + (float(i) + 0.5) * step_size;
        if (t > t1) break;

        vec3 p = eye + ray * t;
        float d = density_at(p, v_sphere, v_params.y) * v_params.x;
        if (d <= 0.001) continue;

        // Beer-Lambert over the step, then front-to-back compositing.
        float absorbed = 1.0 - exp(-d * step_size * 2.4);
        scattered += transmittance * absorbed * lit;
        transmittance *= 1.0 - absorbed;

        // Past this the remaining steps cannot change the pixel.
        if (transmittance < 0.01) break;
    }

    float alpha = 1.0 - transmittance;
    if (alpha <= 0.004) discard;

    // Premultiplied: the pipeline blends with ONE / ONE_MINUS_SRC_ALPHA.
    out_color = vec4(scattered, alpha);
}
