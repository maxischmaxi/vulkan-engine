package main

import "core:log"
import vk "vendor:vulkan"

// Mirrors the std430 layout of the material SSBO. Odin arrays align to their
// element type, which happens to match std430 for this field order -- the
// asserts below keep it that way.
Material :: struct {
	tint:          [4]f32, // multiplies albedo, gives colour variation without new textures
	layer:         u32, // index into all three texture arrays
	uv_scale:      f32, // world metres covered by one texture tile
	roughness_mul: f32,
	metallic:      f32,
	normal_scale:  f32, // 0 flattens the normal map, 1 is as authored
	// Pulls the texture toward its own luminance before the tint is applied.
	// A tint can only scale channels, which cannot remove a colour cast without
	// also amplifying every deviation from it; this can. Desaturating first and
	// colouring second is what lets ten unrelated textures share one palette.
	saturation:    f32,
	_pad:          [2]f32,
}

#assert(size_of(Material) == 48)
#assert(offset_of(Material, layer) == 16)
#assert(offset_of(Material, uv_scale) == 20)
#assert(offset_of(Material, normal_scale) == 32)
#assert(offset_of(Material, saturation) == 36)

// Layer indices into TEXTURE_SETS. Named so the map data reads as material
// intent rather than array offsets.
Material_ID :: enum u32 {
	Wall_Main    = 0,
	Wall_Alt     = 1,
	Wall_Trim    = 2,
	Ground       = 3,
	Floor_Indoor = 4,
	Brick        = 5,
	Brick_Alt    = 6,
	Rock         = 7,
	Rock_Alt     = 8,
	Crate        = 9,
}

// Dust2 is one palette: warm sandstone, from pale plaster down to shaded rock.
// The ambientCG sets are nowhere near that on their own -- Rock030 averages
// 0.08 linear (nearly black on screen), PavingStones141 is a bed of pink and
// blue pebbles, and Bamboo001B sits at 0.40/0.30/0.07 and reads as neon yellow.
//
// Each one is therefore desaturated toward its own luminance first and tinted
// into the palette second. The tint values are the ratio between the measured
// luminance and the ~0.25 albedo dry stone should land on.
MATERIALS := []Material {
	// PaintedPlaster009 -- main walls
	{tint = {1.30, 1.20, 1.02, 1}, layer = 0, uv_scale = 4.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.75},
	// PaintedPlaster014 -- second wall variant
	{tint = {1.05, 0.96, 0.80, 1}, layer = 1, uv_scale = 3.5, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.80},
	// PaintedPlaster016 -- trim and lips
	{tint = {1.10, 1.01, 0.86, 1}, layer = 2, uv_scale = 3.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.80},
	// PavingStones141 -- outdoor ground, the worst colour cast of the set
	{tint = {1.05, 0.96, 0.78, 1}, layer = 3, uv_scale = 2.5, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.35},
	// Tiles130 -- indoor flooring
	{tint = {0.95, 0.88, 0.74, 1}, layer = 4, uv_scale = 2.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.50},
	// Bricks099 -- doorway jambs
	{tint = {1.05, 0.92, 0.74, 1}, layer = 5, uv_scale = 2.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.60},
	// Bricks102 -- steps and platforms
	{tint = {1.15, 1.03, 0.84, 1}, layer = 6, uv_scale = 2.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.65},
	// Rock030 -- outer shell, by far the darkest source texture
	{tint = {2.10, 1.95, 1.65, 1}, layer = 7, uv_scale = 6.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.70},
	// Rock051 -- scenery masses
	{tint = {1.25, 1.15, 0.98, 1}, layer = 8, uv_scale = 6.0, roughness_mul = 1.0, metallic = 0, normal_scale = 1.0, saturation = 0.70},
	// Bamboo001B -- crates, pulled back to a wood brown
	{tint = {0.62, 0.50, 0.34, 1}, layer = 9, uv_scale = 0.8, roughness_mul = 0.9, metallic = 0, normal_scale = 1.0, saturation = 0.55},
}

create_material_buffer :: proc() {
	if len(MATERIALS) > len(TEXTURE_SETS) {
		log.panicf(
			"{} materials reference only {} texture sets",
			len(MATERIALS),
			len(TEXTURE_SETS),
		)
	}
	for m, i in MATERIALS {
		if int(m.layer) >= len(TEXTURE_SETS) {
			log.panicf("Material {} points at layer {}, which does not exist", i, m.layer)
		}
	}

	g.material_buffer, g.material_memory = create_device_local_buffer(MATERIALS, {.STORAGE_BUFFER})
	log.infof("Materials: {}", len(MATERIALS))
}

destroy_material_buffer :: proc() {
	destroy_buffer(g.material_buffer, g.material_memory)
}

// Vulkan needs a plain u32 in the vertex stream, not the enum type.
mat :: proc(id: Material_ID) -> u32 {
	return u32(id)
}
