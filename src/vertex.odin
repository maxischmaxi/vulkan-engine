package main

import vk "vendor:vulkan"

// Positions are already in world space -- the whole static map is baked into
// one buffer, so there is no per-object model matrix to apply. The layout
// follows the glTF convention (including the tangent handedness in w) so that
// imported meshes can feed the same pipeline later on.
Vertex :: struct {
	pos:      [3]f32,
	normal:   [3]f32,
	tangent:  [4]f32,
	uv:       [2]f32,
	material: u32,
}

#assert(size_of(Vertex) == 52)

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
}

// The depth-only pass reads nothing but the position, so it declares only that
// one -- both to silence the validation layer and to skip fetching 40 bytes per
// vertex that would go straight into the bin.
position_attribute_description :: proc() -> [1]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
	}
}

vertex_attribute_descriptions :: proc() -> [5]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, normal)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Vertex, tangent)),
		},
		{
			location = 3,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Vertex, uv)),
		},
		{
			location = 4,
			binding = 0,
			format = .R32_UINT,
			offset = u32(offset_of(Vertex, material)),
		},
	}
}
