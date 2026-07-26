#version 450

// The crosshair arrives as a list of rectangles in framebuffer pixels, already
// snapped to whole pixels by the CPU. Working the geometry out here instead
// would put the edges wherever the window size happened to leave them, and half
// a pixel off is a grey smear where a crisp line belongs.
//
// Five rectangles, six vertices each, no vertex buffer. Unused ones arrive as
// zeroes and rasterise nothing.

layout(push_constant) uniform PushConstants {
    vec4 rects[5]; // x0, y0, x1, y1 in pixels, y growing downward
    vec4 color;
    vec4 screen;   // 1/width, 1/height, cos(rotation), sin(rotation)
} pc;

layout(location = 0) out vec4 v_color;

void main() {
    int rect = gl_VertexIndex / 6;
    int corner = gl_VertexIndex % 6;

    // two triangles over the unit square
    const vec2 QUAD[6] = vec2[6](
        vec2(0, 0), vec2(1, 0), vec2(1, 1),
        vec2(0, 0), vec2(1, 1), vec2(0, 1)
    );

    vec4 r = pc.rects[rect];
    vec2 p = mix(r.xy, r.zw, QUAD[corner]);

    // Only the hit marker is turned, and a diagonal has no pixel grid to sit on
    // in the first place, so it may land wherever it lands.
    vec2 rot = pc.screen.zw;
    if (rot.y != 0.0) {
        vec2 pivot = 0.5 / pc.screen.xy;
        vec2 d = p - pivot;
        p = pivot + vec2(d.x * rot.x - d.y * rot.y, d.x * rot.y + d.y * rot.x);
    }

    gl_Position = vec4(p * pc.screen.xy * 2.0 - 1.0, 0.0, 1.0);
    v_color = pc.color;
}
