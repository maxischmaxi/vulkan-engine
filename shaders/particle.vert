#version 450

#include "frame.glsl"

// One instanced quad per particle, spanned in the vertex shader rather than on
// the CPU: at a couple of thousand live particles the CPU would spend its frame
// writing four vertices each, and the camera basis is right here in the view
// matrix anyway.

layout(location = 0) in vec2 in_corner; // the unit quad, -1..1

layout(location = 1) in vec4 in_center_size; // xyz world centre, w half size
layout(location = 2) in vec4 in_color; // rgb, opacity
layout(location = 3) in vec4 in_params; // look, seed, age 0..1, stretch
layout(location = 4) in vec4 in_axis; // world direction to stretch along

layout(location = 0) out vec2 v_local;
layout(location = 1) out vec4 v_color;
layout(location = 2) out vec4 v_params;
layout(location = 3) out vec3 v_world;

void main() {
    // The camera's world axes are the columns of the view rotation read across
    // -- the transpose of a rotation is its inverse.
    vec3 right = vec3(frame.view[0][0], frame.view[1][0], frame.view[2][0]);
    vec3 up = vec3(frame.view[0][1], frame.view[1][1], frame.view[2][1]);

    float half_size = in_center_size.w;
    float stretch = in_params.w;

    // A stretched particle (a spark) lies along its own direction of travel
    // instead of along the screen's up: what sells a spark is the streak, and a
    // round one is just a dot. Projecting the axis into the screen plane keeps
    // the quad facing the camera while the streak still points where it flies.
    if (stretch > 1.0) {
        vec3 axis = in_axis.xyz;
        vec3 screen_axis = axis - dot(axis, cross(right, up)) * cross(right, up);
        if (dot(screen_axis, screen_axis) > 1e-6) {
            up = normalize(screen_axis);
            right = normalize(cross(up, cross(right, up)));
        }
    }

    vec3 offset = right * (in_corner.x * half_size) +
                  up * (in_corner.y * half_size * max(stretch, 1.0));

    v_world = in_center_size.xyz + offset;
    gl_Position = frame.view_proj * vec4(v_world, 1.0);

    v_local = in_corner;
    v_color = in_color;
    v_params = in_params;
}
