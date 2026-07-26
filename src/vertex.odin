package main

import vk "vendor:vulkan"

Vertex :: struct {
	pos:   [2]f32,
	color: [3]f32,
	uv:    [2]f32,
}

// A quad: four corners, drawn as two triangles via INDICES.
// v is flipped against y because texture row 0 is the top, while model +y points up.
VERTICES := []Vertex {
	{{-0.5, -0.5}, {1, 0, 0}, {0, 1}},
	{{0.5, -0.5}, {0, 1, 0}, {1, 1}},
	{{0.5, 0.5}, {0, 0, 1}, {1, 0}},
	{{-0.5, 0.5}, {1, 1, 0}, {0, 0}},
}

INDICES := []u16{0, 1, 2, 2, 3, 0}

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
}

vertex_attribute_descriptions :: proc() -> [3]vk.VertexInputAttributeDescription {
	return {
		{
			location = 0,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Vertex, pos)),
		},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, color)),
		},
		{
			location = 2,
			binding = 0,
			format = .R32G32_SFLOAT,
			offset = u32(offset_of(Vertex, uv)),
		},
	}
}
