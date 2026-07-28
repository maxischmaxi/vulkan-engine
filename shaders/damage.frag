#version 450

// The directional damage vignette: a soft red band hugging the whole screen
// boundary, thicker and hotter toward each hit's screen heading. All geometry
// is in fractions of the screen height, so the band reads the same at 900p
// and 4K.

layout(push_constant) uniform PushConstants {
    vec4 screen;  // width, height, base ring intensity, unused
    vec4 hits[4]; // screen-space dir x, y (y grows down), intensity, unused
} pc;

layout(location = 0) out vec4 out_color;

// Tuning knobs.
const float BASE_BAND  = 0.05;  // all-around band thickness
const float LOBE_BAND  = 0.16;  // extra thickness at a hit's heading
const float CORNER_R   = 0.25;  // corner rounding of the band
const float LOBE_SIGMA = 0.55;  // angular width of a lobe (radians)
const float MAX_ALPHA  = 0.85;
const vec3  EDGE_COLOR = vec3(0.55, 0.02, 0.02); // deep red, the quiet ring
const vec3  CORE_COLOR = vec3(0.92, 0.13, 0.08); // hotter red inside a lobe

void main() {
    vec2  res      = pc.screen.xy;
    float h        = res.y;
    vec2  half_res = res * 0.5;
    vec2  p        = gl_FragCoord.xy;

    // Interior distance to a rounded-rectangle screen boundary, in pixels:
    // straight edges away from the corners, smooth quarter-circles at them.
    // This is what keeps the band from reading as four hard rects.
    float r = min(CORNER_R * h, min(half_res.x, half_res.y) * 0.9);
    vec2  q = abs(p - half_res) - (half_res - vec2(r));
    float edge_dist = r - length(max(q, 0.0)) - min(max(q.x, q.y), 0.0);
    float d = max(edge_dist, 0.0) / h; // 0 at the edge, grows inward

    // Angular gaussian lobes: each hit widens and brightens the band around
    // its screen heading.
    vec2 v   = p - half_res;
    vec2 ang = length(v) > 1e-3 ? normalize(v) : vec2(0.0, -1.0);

    float lobe      = 0.0;         // widens the band
    float intensity = pc.screen.z; // directionless base keeps the ring alive
    for (int i = 0; i < 4; i++) {
        float s = pc.hits[i].z;
        if (s <= 0.0) continue;
        float a = acos(clamp(dot(ang, pc.hits[i].xy), -1.0, 1.0));
        float w = exp(-(a * a) / (2.0 * LOBE_SIGMA * LOBE_SIGMA));
        lobe      = max(lobe, w * s);
        intensity = max(intensity, w * s);
    }

    float thickness = BASE_BAND + LOBE_BAND * lobe;
    float fall = 1.0 - smoothstep(0.0, thickness, d);
    fall *= fall; // bias toward the edge: saturated rim, soft inner falloff

    // Display-space sRGB like the rest of the HUD -- the swapchain encodes,
    // no tonemap. See hud_quad.frag.
    vec3  color = mix(EDGE_COLOR, CORE_COLOR, clamp(lobe, 0.0, 1.0));
    float alpha = fall * intensity * MAX_ALPHA;
    out_color = vec4(color, alpha);
}
