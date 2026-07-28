#version 450

// One fullscreen triangle from gl_VertexIndex: no buffers, no varyings. The
// fragment shader works entirely from gl_FragCoord.

void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2); // (0,0) (2,0) (0,2)
    // z = 1 is the near plane under reversed-Z -- see hud_quad.vert. Depth is
    // disabled in this pipeline; kept for consistency.
    gl_Position = vec4(p * 2.0 - 1.0, 1.0, 1.0);
}
