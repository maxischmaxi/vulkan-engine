#version 450

// Overdraw heatmap (debug view F12). Rendered additively with the world's own
// depth state, so what accumulates is exactly the fragments the GPU shades
// after early-z -- the quantity a depth prepass or front-to-back order would
// reduce. One surface reads dim red; every extra shaded layer stacks another
// eighth on top.

layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(0.125, 0.02, 0.0, 1.0);
}
