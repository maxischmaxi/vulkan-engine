#version 450

#include "frame.glsl"

// Skinned meshes -- the players. Same vertex outputs as model.vert, so the map's
// own fragment shader lights a character without knowing it is one.
//
// The view-projection is a push constant for the same reason it is there: this
// pass shares its pipeline layout with the models, and the viewmodel renders
// through a narrower projection than the world does.
layout(push_constant) uniform PushConstants {
    mat4 view_proj;
} pc;

// Every character's joints end to end, rewritten every frame. Lives in the
// frame set because that is what the set is for, and because the shadow pass
// binds nothing else.
layout(std430, set = 0, binding = 4) readonly buffer Joints {
    mat4 joints[];
};

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_tangent;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in uint in_material;
layout(location = 5) in uvec4 in_joints;
layout(location = 6) in vec4 in_weights; // UNORM, so already 0..1 and summing to 1

// per instance
layout(location = 7) in vec4 in_model0;
layout(location = 8) in vec4 in_model1;
layout(location = 9) in vec4 in_model2;
layout(location = 10) in vec4 in_model3;
layout(location = 11) in uvec2 in_indices; // joint block base, material offset

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_tangent;
layout(location = 3) out vec2 v_uv;
layout(location = 4) out flat uint v_material;
layout(location = 5) out float v_view_depth;
layout(location = 6) out flat float v_receive_shadow;

mat4 skin_matrix(uvec4 indices, vec4 weights, uint base) {
    return weights.x * joints[base + indices.x]
         + weights.y * joints[base + indices.y]
         + weights.z * joints[base + indices.z]
         + weights.w * joints[base + indices.w];
}

void main() {
    mat4 model = mat4(in_model0, in_model1, in_model2, in_model3);
    mat4 skin = skin_matrix(in_joints, in_weights, in_indices.x);

    vec4 world = model * (skin * vec4(in_position, 1.0));
    gl_Position = pc.view_proj * world;

    // Nothing in the animation library scales a bone -- the converter stops if
    // one ever does -- so every joint matrix is a rotation and a translation and
    // needs no inverse transpose. The instance matrix scales uniformly, which
    // normalising handles. Between two blended joints the sum of two rotations
    // is not quite a rotation, which is the ordinary cost of linear blend
    // skinning and shows up nowhere a normalize does not fix.
    mat3 pose = mat3(model) * mat3(skin);

    v_world_pos = world.xyz;
    v_normal    = normalize(pose * in_normal);
    v_tangent   = vec4(normalize(pose * in_tangent.xyz), in_tangent.w);
    v_uv        = in_uv;
    // The two team colours are two rows of the material table, so which team a
    // character is on is an offset rather than a second mesh or a second draw.
    v_material  = in_material + in_indices.y;

    v_view_depth = -(frame.view * world).z;
    v_receive_shadow = 1.0;
}
