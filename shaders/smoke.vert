#version 450

#include "frame.glsl"

// One box per cloud, sized to the sphere it contains. Proxy geometry rather
// than a fullscreen quad: a smoke covers a fraction of the screen, and marching
// rays for every pixel of the frame to find that out is most of the cost of the
// effect for none of the picture.

layout(location = 0) in vec3 in_position; // unit cube, -0.5 .. 0.5

// Per-instance: where the cloud is, how big it is, and how solid.
layout(location = 1) in vec4 in_sphere;   // xyz centre, w radius
layout(location = 2) in vec4 in_params;   // density, seed, 0, 0

layout(location = 0) out vec3 v_world;
layout(location = 1) out vec4 v_sphere;
layout(location = 2) out vec4 v_params;

void main() {
    // The box is grown slightly past the sphere: at exactly the radius the
    // silhouette clips the very edge of the volume, and the rim of the cloud
    // ends up cut off by its own proxy.
    vec3 world = in_sphere.xyz + in_position * in_sphere.w * 2.2;

    v_world = world;
    v_sphere = in_sphere;
    v_params = in_params;
    gl_Position = frame.view_proj * vec4(world, 1.0);
}
