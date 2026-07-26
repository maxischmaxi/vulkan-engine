#ifndef TONEMAP_GLSL
#define TONEMAP_GLSL

// ACES filmic approximation by Krzysztof Narkowicz. Compresses the highlights so
// a bright sun does not clip to flat white.
vec3 tonemap_aces(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// The swapchain is an _SRGB format, so the hardware applies the transfer curve
// on write. Doing it here as well would wash the image out.
vec4 present(vec3 hdr, float exposure) {
    return vec4(tonemap_aces(hdr * exposure), 1.0);
}

#endif
