#ifndef NOISE_GLSL
#define NOISE_GLSL

// Cheap 3D value noise. Hash-based rather than texture-based: one less
// descriptor, one less asset, and at the step counts it is used with the
// difference is not visible.
//
// Shared by the volumetric smoke and the particles, which is the whole reason
// it lives in a header: two copies would drift, and a puff at the edge of a
// cloud has to be made of the same stuff the cloud is.
float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    // Smoothstep weights: linear interpolation between lattice points leaves
    // visible creases along the cell boundaries.
    f = f * f * (3.0 - 2.0 * f);

    float n000 = hash13(i + vec3(0, 0, 0));
    float n100 = hash13(i + vec3(1, 0, 0));
    float n010 = hash13(i + vec3(0, 1, 0));
    float n110 = hash13(i + vec3(1, 1, 0));
    float n001 = hash13(i + vec3(0, 0, 1));
    float n101 = hash13(i + vec3(1, 0, 1));
    float n011 = hash13(i + vec3(0, 1, 1));
    float n111 = hash13(i + vec3(1, 1, 1));

    return mix(
        mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
        mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
        f.z);
}

float fbm(vec3 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; ++i) {
        sum += amplitude * value_noise(p);
        p *= 2.03;
        amplitude *= 0.5;
    }
    return sum;
}

#endif
