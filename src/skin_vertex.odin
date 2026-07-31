package main

import vk "vendor:vulkan"

// The skinned counterpart to Vertex. Its first 52 bytes are laid out exactly
// like one, on purpose: the fragment stage cannot tell a character apart from a
// wall, so world.frag serves both and there is no second lighting path.
//
// It still needs a buffer of its own rather than a longer shared Vertex. A
// vertex binding carries exactly one stride, so widening Vertex would widen the
// baked map and all 61 static meshes by eight bytes they would never read -- and
// it would break the memcpy in mesh.odin, which is the reason that loader is as
// short as it is.
Skin_Vertex :: struct {
	pos:      [3]f32,
	normal:   [3]f32,
	tangent:  [4]f32,
	uv:       [2]f32,
	material: u32,
	joints:   [4]u8, // slots into the skeleton
	weights:  [4]u8, // normalised by the converter so the four sum to 255
}

#assert(size_of(Skin_Vertex) == 60)
#assert(offset_of(Skin_Vertex, joints) == 52)

skin_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Skin_Vertex), inputRate = .VERTEX}
}

// The world's five attributes, then the two the skin adds. Weights arrive
// UNORM so the shader reads 0..1 without dividing, joints UINT because they are
// indices and interpolating them would be meaningless.
skin_attribute_descriptions :: proc() -> [7]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Skin_Vertex, pos))},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Skin_Vertex, normal)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Skin_Vertex, tangent)),
		},
		{location = 3, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Skin_Vertex, uv))},
		{location = 4, binding = 0, format = .R32_UINT, offset = u32(offset_of(Skin_Vertex, material))},
		{
			location = 5,
			binding = 0,
			format = .R8G8B8A8_UINT,
			offset = u32(offset_of(Skin_Vertex, joints)),
		},
		{
			location = 6,
			binding = 0,
			format = .R8G8B8A8_UNORM,
			offset = u32(offset_of(Skin_Vertex, weights)),
		},
	}
}

// The depth-only pass still has to skin -- a shadow of the bind pose would not
// follow the animation -- so it reads position, joints and weights.
skin_shadow_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Skin_Vertex, pos))},
		{
			location = 1,
			binding = 0,
			format = .R8G8B8A8_UINT,
			offset = u32(offset_of(Skin_Vertex, joints)),
		},
		{
			location = 2,
			binding = 0,
			format = .R8G8B8A8_UNORM,
			offset = u32(offset_of(Skin_Vertex, weights)),
		},
	}
}
