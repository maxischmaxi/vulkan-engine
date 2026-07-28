package main

import "core:log"
import "game"
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

// The enum itself lives with the map data in the game package; the material
// system is its client-side consumer, so the short name stays usable here.
Material_ID :: game.Material_ID

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
	{
		tint = {1.30, 1.20, 1.02, 1},
		layer = 0,
		uv_scale = 4.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.75,
	},
	// PaintedPlaster014 -- second wall variant
	{
		tint = {1.05, 0.96, 0.80, 1},
		layer = 1,
		uv_scale = 3.5,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.80,
	},
	// PaintedPlaster016 -- trim and lips
	{
		tint = {1.10, 1.01, 0.86, 1},
		layer = 2,
		uv_scale = 3.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.80,
	},
	// PavingStones141 -- outdoor ground, the worst colour cast of the set
	{
		tint = {1.05, 0.96, 0.78, 1},
		layer = 3,
		uv_scale = 2.5,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.35,
	},
	// Tiles130 -- indoor flooring
	{
		tint = {0.95, 0.88, 0.74, 1},
		layer = 4,
		uv_scale = 2.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.50,
	},
	// Bricks099 -- doorway jambs
	{
		tint = {1.05, 0.92, 0.74, 1},
		layer = 5,
		uv_scale = 2.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.60,
	},
	// Bricks102 -- steps and platforms
	{
		tint = {1.15, 1.03, 0.84, 1},
		layer = 6,
		uv_scale = 2.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.65,
	},
	// Rock030 -- outer shell, by far the darkest source texture
	{
		tint = {2.10, 1.95, 1.65, 1},
		layer = 7,
		uv_scale = 6.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.70,
	},
	// Rock051 -- scenery masses
	{
		tint = {1.25, 1.15, 0.98, 1},
		layer = 8,
		uv_scale = 6.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.70,
	},
	// Bamboo001B -- crates, pulled back to a wood brown
	{
		tint = {0.62, 0.50, 0.34, 1},
		layer = 9,
		uv_scale = 0.8,
		roughness_mul = 0.9,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.55,
	},
	// Railing -- decor marker; wood fallback for when the marking is skipped
	{
		tint = {0.62, 0.50, 0.34, 1},
		layer = 9,
		uv_scale = 0.8,
		roughness_mul = 0.9,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.55,
	},
	// Fence -- decor marker, same wood fallback
	{
		tint = {0.62, 0.50, 0.34, 1},
		layer = 9,
		uv_scale = 0.8,
		roughness_mul = 0.9,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.55,
	},
	// Pillar -- decor marker; trim plaster fallback
	{
		tint = {1.10, 1.01, 0.86, 1},
		layer = 2,
		uv_scale = 3.0,
		roughness_mul = 1.0,
		metallic = 0,
		normal_scale = 1.0,
		saturation = 0.80,
	},
	// ------------------------------------------------------------- models
	//
	// Imported geometry carries its own UVs, so uv_scale is 1 -- the world's
	// value is metres-per-tile, which means nothing to a mesh whose UVs already
	// span its own surface. Saturation stays at 1: these textures were painted
	// for the object rather than pulled from a photo library, so there is no
	// colour cast to pull out.
	//
	// Skin and gunmetal share one atlas layer and differ only here.
	{
		// arms
		tint          = {1, 1, 1, 1},
		layer         = 10,
		uv_scale      = 1.0,
		roughness_mul = 1.05,
		metallic      = 0,
		normal_scale  = 1.0,
		saturation    = 1.0,
	},
	{
		// rifle, pistol and the rounds in their magazines
		tint          = {1, 1, 1, 1},
		layer         = 10,
		uv_scale      = 1.0,
		roughness_mul = 0.8,
		// Not fully metallic: the retro textures paint their own highlights, and
		// a metallic of 1 would drop the diffuse term those rely on.
		metallic      = 0.45,
		normal_scale  = 1.0,
		saturation    = 1.0,
	},
	{
		// Props, mapped onto the flat colour palette they were authored against.
		// The palette is a bright toy-box green and yellow; pulled toward the
		// map's sandstone the same way the world textures are, or the crates
		// read as belonging to a different game.
		tint          = {0.92, 0.82, 0.62, 1},
		layer         = 11,
		uv_scale      = 1.0,
		roughness_mul = 1.0,
		metallic      = 0,
		normal_scale  = 1.0,
		saturation    = 0.55,
	},
	// The gun pack's swatch palette. Roughness varies per swatch inside the
	// texture, so the two entries only split metal from dielectric.
	{
		// gun_matte: polymer, wood, glass
		tint          = {1, 1, 1, 1},
		layer         = 12,
		uv_scale      = 1.0,
		roughness_mul = 1.0,
		metallic      = 0,
		normal_scale  = 1.0,
		saturation    = 1.0,
	},
	{
		// gun_metal: bare metal parts
		tint          = {1, 1, 1, 1},
		layer         = 12,
		uv_scale      = 1.0,
		roughness_mul = 1.0,
		metallic      = 0.6,
		normal_scale  = 1.0,
		saturation    = 1.0,
	},
	{
		// Modular decoration pieces on their own flat-colour palette, pulled
		// toward the sandstone the same way the prop palette is.
		tint          = {0.92, 0.82, 0.62, 1},
		layer         = 13,
		uv_scale      = 1.0,
		roughness_mul = 1.0,
		metallic      = 0,
		normal_scale  = 1.0,
		saturation    = 0.55,
	},
}

// Model materials are appended past the map's, so game.Material_ID keeps meaning
// "something a map is authored in" and these stay a client-side detail. The
// order has to match the model entries at the end of MATERIALS above; the load
// checks it.
MODEL_MAT_RETRO_ARMS :: u32(len(game.Material_ID))
MODEL_MAT_RETRO_GUNS :: MODEL_MAT_RETRO_ARMS + 1
MODEL_MAT_PROP_PALETTE :: MODEL_MAT_RETRO_ARMS + 2
MODEL_MAT_GUN_MATTE :: MODEL_MAT_RETRO_ARMS + 3
MODEL_MAT_GUN_METAL :: MODEL_MAT_RETRO_ARMS + 4
MODEL_MAT_MOD_PALETTE :: MODEL_MAT_RETRO_ARMS + 5
MODEL_MATERIAL_COUNT :: 6

// Everything behind descriptor set 1: the material table and the texture arrays
// it indexes into. None of it changes after load.
Material_System :: struct {
	buffer:     vk.Buffer,
	memory:     vk.DeviceMemory,
	albedo:     Texture_Array,
	normal:     Texture_Array,
	orm:        Texture_Array,
	sampler:    vk.Sampler,
	mip_levels: u32,
}

material_system: Material_System

create_material_buffer :: proc() {
	// Several materials may share a texture set, so the only thing worth
	// checking is that every layer index actually exists.
	for m, i in MATERIALS {
		if int(m.layer) >= len(TEXTURE_SETS) {
			log.panicf("Material {} points at layer {}, which does not exist", i, m.layer)
		}
	}

	// The model material constants are offsets into this table rather than
	// entries of an enum, so this is what keeps them pointing at the right rows.
	if len(MATERIALS) != int(MODEL_MAT_RETRO_ARMS) + MODEL_MATERIAL_COUNT {
		log.panicf(
			"{} materials, but {} map materials plus {} model materials were expected",
			len(MATERIALS),
			MODEL_MAT_RETRO_ARMS,
			MODEL_MATERIAL_COUNT,
		)
	}

	material_system.buffer, material_system.memory = create_device_local_buffer(
		MATERIALS,
		{.STORAGE_BUFFER},
	)
	log.infof("Materials: {}", len(MATERIALS))
}

destroy_material_buffer :: proc() {
	destroy_buffer(material_system.buffer, material_system.memory)
}

// Vulkan needs a plain u32 in the vertex stream, not the enum type.
mat :: proc(id: Material_ID) -> u32 {
	return u32(id)
}
