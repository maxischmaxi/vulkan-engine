package main

import "core:image"
import "core:image/png"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import vk "vendor:vulkan"

// One directory per ambientCG set under textures/, holding Color.png,
// NormalGL.png, Roughness.png and AmbientOcclusion.png. The index into this
// list is the array layer every material refers to.
TEXTURE_SETS := []string {
	"PaintedPlaster009",
	"PaintedPlaster014",
	"PaintedPlaster016",
	"PavingStones141",
	"Tiles130",
	"Bricks099",
	"Bricks102",
	"Rock030",
	"Rock051",
	"Bamboo001B",
	// Written by `just models` rather than downloaded: model textures are not
	// tileable, so they are baked at exactly the layer size and the tiling in
	// blit_layer never comes into play. Everything else about them -- four maps,
	// one directory, one layer -- is the same deal as an ambientCG set.
	"RetroWeapons",
	"PropPalette",
	"GunPalette",
}

TEXTURE_DIR :: "textures"

ALBEDO_FORMAT :: vk.Format.R8G8B8A8_SRGB // gamma-encoded, GPU linearises on read
NORMAL_FORMAT :: vk.Format.R8G8B8A8_UNORM // vectors, must not be gamma-decoded
ORM_FORMAT :: vk.Format.R8G8B8A8_UNORM // R=occlusion G=roughness B=metallic

Texture_Array :: struct {
	image:  vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
}

// Header fields we need before allocating: PNG stores width and height as
// big-endian u32 at a fixed offset, so there is no need to decode anything.
png_dimensions :: proc(path: string) -> (width, height: int, ok: bool) {
	handle, err := os.open(path)
	if err != nil do return 0, 0, false
	defer os.close(handle)

	header: [24]byte
	n, read_err := os.read(handle, header[:])
	if read_err != nil || n < 24 do return 0, 0, false

	be_u32 :: proc(b: []byte) -> int {
		return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])
	}
	return be_u32(header[16:20]), be_u32(header[20:24]), true
}

set_path :: proc(set, map_name: string, allocator := context.allocator) -> string {
	return strings.concatenate({TEXTURE_DIR, "/", set, "/", map_name, ".png"}, allocator)
}

Load_Job :: struct {
	first, last:   int, // half-open range of TEXTURE_SETS this worker owns
	width, height: int, // target size of every array layer
	albedo:        []byte,
	normal:        []byte,
	orm:           []byte,
	failed:        bool,
}

// Copies one decoded source image into a layer, repeating it if the source is
// smaller. The ambientCG sets are seamlessly tileable, so a set that ships at
// 1024x512 becomes a 1024x1024 layer showing the pattern twice with no seam.
// src_stride is the byte distance between source pixels, src_offset picks the
// channel to read.
blit_layer :: proc(
	dst: []byte,
	dst_channel: int,
	dst_channels: int,
	dst_w, dst_h: int,
	src: []byte,
	src_w, src_h: int,
	src_stride, src_offset: int,
) {
	for y in 0 ..< dst_h {
		sy := y % src_h
		for x in 0 ..< dst_w {
			sx := x % src_w
			si := (sy * src_w + sx) * src_stride + src_offset
			di := (y * dst_w + x) * dst_channels + dst_channel
			dst[di] = src[si]
		}
	}
}

load_texture_worker :: proc(job: ^Load_Job) {
	layer_bytes := job.width * job.height * 4

	for set_index in job.first ..< job.last {
		set := TEXTURE_SETS[set_index]
		base := layer_bytes * set_index

		// Color: 8-bit RGB in the archives, alpha added so the copy is a
		// straight memcpy-shaped loop into an RGBA layer.
		{
			path := set_path(set, "Color", context.temp_allocator)
			img, err := png.load_from_file(path, {.alpha_add_if_missing})
			if err != nil {
				log.errorf("{}: {}", path, err)
				job.failed = true
				return
			}
			defer image.destroy(img)

			src := img.pixels.buf[:]
			for c in 0 ..< 3 {
				blit_layer(
					job.albedo[base:base + layer_bytes],
					c,
					4,
					job.width,
					job.height,
					src,
					img.width,
					img.height,
					img.channels,
					c,
				)
			}
			// alpha is unused by the world shader but must be defined
			for i := 3; i < layer_bytes; i += 4 {
				job.albedo[base + i] = 255
			}
		}

		// NormalGL: 16-bit RGB. The loader returns host byte order, so the
		// high byte of each channel sits at the odd index -- taking it is an
		// exact 16->8 bit reduction, which is all a tangent-space normal needs.
		{
			path := set_path(set, "NormalGL", context.temp_allocator)
			img, err := png.load_from_file(path, {})
			if err != nil {
				log.errorf("{}: {}", path, err)
				job.failed = true
				return
			}
			defer image.destroy(img)

			src := img.pixels.buf[:]
			bytes_per_channel := img.depth / 8
			stride := img.channels * bytes_per_channel
			high_byte := bytes_per_channel - 1

			for c in 0 ..< 3 {
				blit_layer(
					job.normal[base:base + layer_bytes],
					c,
					4,
					job.width,
					job.height,
					src,
					img.width,
					img.height,
					stride,
					c * bytes_per_channel + high_byte,
				)
			}
			for i := 3; i < layer_bytes; i += 4 {
				job.normal[base + i] = 255
			}
		}

		// AmbientOcclusion -> R, Roughness -> G. Both ship as greyscale, which
		// the loader expands to three identical channels, so channel 0 is the
		// value. Packing them together saves a sampler binding.
		orm := job.orm[base:base + layer_bytes]
		for entry in ([2]struct {
				name:    string,
				channel: int,
			}{{"AmbientOcclusion", 0}, {"Roughness", 1}}) {
			path := set_path(set, entry.name, context.temp_allocator)
			img, err := png.load_from_file(path, {})
			if err != nil {
				log.errorf("{}: {}", path, err)
				job.failed = true
				return
			}
			defer image.destroy(img)

			bytes_per_channel := img.depth / 8
			blit_layer(
				orm,
				entry.channel,
				4,
				job.width,
				job.height,
				img.pixels.buf[:],
				img.width,
				img.height,
				img.channels * bytes_per_channel,
				bytes_per_channel - 1,
			)
		}
		// B holds metallic: every ambientCG set here is a dielectric, and the
		// per-material constant overrides this anyway.
		for i := 2; i < layer_bytes; i += 4 {
			orm[i] = 0
		}

		free_all(context.temp_allocator)
	}
}

// Uploads all layers of one array in a single command buffer, then builds the
// full mip chain.
upload_texture_array :: proc(
	pixels: []byte,
	width, height: u32,
	layers: u32,
	format: vk.Format,
	mip_levels: u32,
) -> (
	result: Texture_Array,
) {
	size := vk.DeviceSize(len(pixels))

	staging_buffer, staging_memory := create_buffer(
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vk.FreeMemory(g.device, staging_memory, nil)
	defer vk.DestroyBuffer(g.device, staging_buffer, nil)

	mapped: rawptr
	vk_check(vk.MapMemory(g.device, staging_memory, 0, size, {}, &mapped))
	mem.copy(mapped, raw_data(pixels), int(size))
	vk.UnmapMemory(g.device, staging_memory)

	// TRANSFER_SRC is needed because mipmap generation blits from this image too
	result.image, result.memory = create_image(
		width,
		height,
		mip_levels,
		format,
		.OPTIMAL,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
		layers,
	)

	layer_bytes := vk.DeviceSize(width * height * 4)
	regions := make([]vk.BufferImageCopy, layers, context.temp_allocator)
	for i in 0 ..< layers {
		regions[i] = {
			bufferOffset = layer_bytes * vk.DeviceSize(i),
			imageSubresource = {
				aspectMask = {.COLOR},
				mipLevel = 0,
				baseArrayLayer = i,
				layerCount = 1,
			},
			imageExtent = {width, height, 1},
		}
	}

	cmd := begin_single_time_commands()
	transition_image(
		cmd,
		result.image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{},
		{.TRANSFER_WRITE},
		0,
		mip_levels,
		{.COLOR},
		0,
		layers,
	)
	vk.CmdCopyBufferToImage(
		cmd,
		staging_buffer,
		result.image,
		.TRANSFER_DST_OPTIMAL,
		layers,
		raw_data(regions),
	)
	end_single_time_commands(cmd)

	// leaves every level and layer in SHADER_READ_ONLY_OPTIMAL
	generate_mipmaps(result.image, format, i32(width), i32(height), mip_levels, layers)

	view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = result.image,
		viewType = .D2_ARRAY,
		format = format,
		components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = layers,
		},
	}
	vk_check(vk.CreateImageView(g.device, &view_ci, nil, &result.view))

	return
}

create_texture_arrays :: proc() {
	start := time.now()
	layers := len(TEXTURE_SETS)

	// Every layer of an array must have the same size, so the largest set wins
	// and smaller ones get tiled up to it.
	width, height := 0, 0
	for set in TEXTURE_SETS {
		path := set_path(set, "Color", context.temp_allocator)
		w, h, ok := png_dimensions(path)
		if !ok {
			log.panicf("Cannot read {} -- run `just textures` to unpack the ambientCG zips", path)
		}
		width = max(width, w)
		height = max(height, h)
	}
	log.infof("Texture arrays: {} layers at {}x{}", layers, width, height)

	layer_bytes := width * height * 4
	total := layer_bytes * layers

	albedo_pixels := make([]byte, total)
	normal_pixels := make([]byte, total)
	orm_pixels := make([]byte, total)
	defer delete(albedo_pixels)
	defer delete(normal_pixels)
	defer delete(orm_pixels)

	// Decoding 40 PNGs is the slowest part of startup by far, and the layers
	// are independent, so each worker owns a disjoint slice of the output.
	//
	// The second division matters: 10 layers across 8 workers is 2 layers each,
	// which only five workers can actually take. Spawning the other three costs
	// three threads that immediately exit.
	per_worker := (layers + 8 - 1) / 8
	worker_count := (layers + per_worker - 1) / per_worker

	jobs := make([]Load_Job, worker_count, context.temp_allocator)
	threads := make([]^thread.Thread, worker_count, context.temp_allocator)
	for i in 0 ..< worker_count {
		jobs[i] = Load_Job {
			first  = i * per_worker,
			last   = min((i + 1) * per_worker, layers),
			width  = width,
			height = height,
			albedo = albedo_pixels,
			normal = normal_pixels,
			orm    = orm_pixels,
		}
		threads[i] = thread.create_and_start_with_poly_data(
			&jobs[i],
			load_texture_worker,
			g.odin_context,
		)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	for &job in jobs {
		if job.failed do log.panic("Texture loading failed")
	}

	// full mip chain down to 1x1
	material_system.mip_levels = u32(math.floor(math.log2(f32(max(width, height))))) + 1

	material_system.albedo = upload_texture_array(
		albedo_pixels,
		u32(width),
		u32(height),
		u32(layers),
		ALBEDO_FORMAT,
		material_system.mip_levels,
	)

	// Normal and ORM only carry two channels the shader reads, so they compress
	// to BC5 at a quarter the footprint -- see texture_bc.odin. Albedo stays
	// uncompressed: encoding colour well is a different problem.
	if g.bc_enabled {
		material_system.normal = upload_texture_array_bc5(
			normal_pixels,
			u32(width),
			u32(height),
			u32(layers),
			material_system.mip_levels,
		)
		material_system.orm = upload_texture_array_bc5(
			orm_pixels,
			u32(width),
			u32(height),
			u32(layers),
			material_system.mip_levels,
		)
	} else {
		material_system.normal = upload_texture_array(
			normal_pixels,
			u32(width),
			u32(height),
			u32(layers),
			NORMAL_FORMAT,
			material_system.mip_levels,
		)
		material_system.orm = upload_texture_array(
			orm_pixels,
			u32(width),
			u32(height),
			u32(layers),
			ORM_FORMAT,
			material_system.mip_levels,
		)
	}

	// mips add roughly a third on top of level 0
	rgba_mb := f64(total) / (1024 * 1024) * 1.34
	bc_mb := rgba_mb / 4
	log.infof(
		"Texture arrays ready: {} mip levels, {:.1f} MB VRAM, loaded in {}",
		material_system.mip_levels,
		g.bc_enabled ? rgba_mb + 2 * bc_mb : 3 * rgba_mb,
		time.since(start),
	)
}

// Anisotropy is the cheapest quality dial there is on a bandwidth-starved GPU:
// most of a shooter's screen is floor seen at a glancing angle, which is exactly
// the case anisotropic filtering spends its samples on, and this shader takes
// three of those per fragment. A positive LOD bias pushes the whole chain toward
// smaller mips, trading sharpness for cache hits.
create_texture_sampler :: proc() {
	aniso := g.anisotropy_enabled && settings.anisotropy > 1

	sampler_ci := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		mipmapMode              = .LINEAR,
		addressModeU            = .REPEAT,
		addressModeV            = .REPEAT,
		addressModeW            = .REPEAT,
		mipLodBias              = settings.mip_lod_bias,
		anisotropyEnable        = b32(aniso),
		maxAnisotropy           = aniso ? f32(settings.anisotropy) : 1,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		minLod                  = 0,
		maxLod                  = f32(material_system.mip_levels),
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
	}
	vk_check(vk.CreateSampler(g.device, &sampler_ci, nil, &material_system.sampler))

	if !g.anisotropy_enabled {
		log.info("Sampler: linear, repeat, anisotropy unsupported")
		return
	}
	log.infof(
		"Sampler: linear, repeat, {}x anisotropic, lod bias {:.2f}",
		aniso ? int(settings.anisotropy) : 1,
		settings.mip_lod_bias,
	)
}

// Anisotropy and LOD bias live entirely in sampler state, so changing them costs
// one object and one descriptor write -- no pipeline touches them.
rebuild_samplers :: proc() {
	vk_check(vk.DeviceWaitIdle(g.device))

	vk.DestroySampler(g.device, material_system.sampler, nil)
	create_texture_sampler()
	write_material_set()
}

destroy_texture_arrays :: proc() {
	vk.DestroySampler(g.device, material_system.sampler, nil)
	for arr in ([]Texture_Array {
			material_system.albedo,
			material_system.normal,
			material_system.orm,
		}) {
		vk.DestroyImageView(g.device, arr.view, nil)
		vk.DestroyImage(g.device, arr.image, nil)
		vk.FreeMemory(g.device, arr.memory, nil)
	}
}
