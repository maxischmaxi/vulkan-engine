package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import vk "vendor:vulkan"

// Creating a graphics pipeline is a hundred lines of structs of which maybe six
// differ between any two pipelines. This collapses that to the six.
//
// Enum orders and field names are chosen so the zero value is the common case
// (Odin has no default struct field values): back-face culling, depth test with
// LESS, depth writes on, no blending. A pipeline definition then only spells out
// where it deviates.

Cull_Mode :: enum {
	Back, // zero value
	None,
	Front,
}

// The main camera renders reversed-Z (see perspective_tangents in frame.odin):
// the near plane is 1, the far plane is 0, so nearer means greater. The shadow
// cascades are orthographic and therefore linear in depth, where reversed-Z has
// no 1/z distribution to cancel and buys nothing, so they keep the plain
// near-is-zero convention -- and have to say so, because the zero value here is
// the main camera's.
//
// The names say which way is nearer rather than naming the raw comparison, so a
// pipeline that picks the wrong convention reads wrong.
Depth_Test :: enum {
	Nearer, // zero value: reversed-Z
	Nearer_Or_Equal, // reversed-Z, for surfaces coplanar with what they sit on
	Forward_Less, // plain near-is-zero depth -- the shadow cascades only
	Always,
	Disabled,
}

Blend_Mode :: enum {
	Opaque, // zero value
	Alpha,
	Additive, // src + dst, the overdraw heatmap's accumulation
	// Colour already multiplied by its own alpha, which is what front-to-back
	// volume compositing produces: the shader has done the weighting, so the
	// blend must not do it a second time.
	Premultiplied,
}

Pipeline_Desc :: struct {
	name:           string, // for the log line only
	vert_spv:       []byte,
	frag_spv:       []byte, // nil means depth-only
	bindings:       []vk.VertexInputBindingDescription,
	attributes:     []vk.VertexInputAttributeDescription,
	set_layouts:    []vk.DescriptorSetLayout,
	push_constants: []vk.PushConstantRange,
	color_formats:  []vk.Format,
	depth_format:   vk.Format,
	samples:        vk.SampleCountFlags, // zero means _1
	cull:           Cull_Mode,
	depth_test:     Depth_Test,
	no_depth_write: bool,
	// Declares the colour attachment without touching it. A depth-only pipeline
	// inside a colour-attached rendering block still has to match the block's
	// attachment count, it just must not write.
	no_color_write: bool,
	blend:          Blend_Mode,
	depth_bias:     bool,
	extra_dynamic:  []vk.DynamicState,
	spec:           []Spec_Constant,
}

// A quality setting compiled into the shader rather than branched on.
//
// The rule this codebase follows: express a setting as data first, and reach for
// a compiled variant only where it removes work from an inner loop. Anisotropy
// is sampler state and costs nothing; the shadow tap count is a loop bound, and
// baking it lets the loop unroll and a cascade count of zero delete the whole
// texture-fetch path. Only ever one variant of each pipeline exists at a time --
// the one the current settings need.
Spec_Constant :: struct {
	id:    u32,
	value: i32,
}

Pipeline :: struct {
	pipeline: vk.Pipeline,
	layout:   vk.PipelineLayout,
}

// #load gives no alignment guarantee, but pCode must be 4-byte aligned
create_shader_module :: proc(code: []byte) -> vk.ShaderModule {
	if len(code) % 4 != 0 do log.panicf("SPIR-V size {} is not a multiple of 4", len(code))

	words := make([]u32, len(code) / 4, context.temp_allocator)
	mem.copy(raw_data(words), raw_data(code), len(code))

	module_ci := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(words),
	}

	module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(g.device, &module_ci, nil, &module))
	return module
}

@(private = "file")
compare_op :: proc(test: Depth_Test) -> vk.CompareOp {
	switch test {
	case .Nearer:
		return .GREATER
	case .Nearer_Or_Equal:
		return .GREATER_OR_EQUAL
	case .Forward_Less:
		return .LESS
	case .Always, .Disabled:
		return .ALWAYS
	}
	return .GREATER
}

@(private = "file")
cull_flags :: proc(cull: Cull_Mode) -> vk.CullModeFlags {
	switch cull {
	case .Back:
		return {.BACK}
	case .None:
		return {}
	case .Front:
		return {.FRONT}
	}
	return {.BACK}
}

build_pipeline :: proc(desc: Pipeline_Desc) -> Pipeline {
	result: Pipeline

	vert_module := create_shader_module(desc.vert_spv)
	defer vk.DestroyShaderModule(g.device, vert_module, nil)

	// One entry per constant, all i32, tightly packed -- so the map entries are
	// simply index * 4 and there is no alignment question to get wrong.
	spec_entries := make([]vk.SpecializationMapEntry, len(desc.spec), context.temp_allocator)
	spec_values := make([]i32, len(desc.spec), context.temp_allocator)
	for c, i in desc.spec {
		spec_entries[i] = {
			constantID = c.id,
			offset     = u32(i * size_of(i32)),
			size       = size_of(i32),
		}
		spec_values[i] = c.value
	}
	spec_info := vk.SpecializationInfo {
		mapEntryCount = u32(len(spec_entries)),
		pMapEntries   = raw_data(spec_entries),
		dataSize      = len(spec_values) * size_of(i32),
		pData         = raw_data(spec_values),
	}
	spec := len(desc.spec) > 0 ? &spec_info : nil

	stages := make([dynamic]vk.PipelineShaderStageCreateInfo, 0, 2, context.temp_allocator)
	append(
		&stages,
		vk.PipelineShaderStageCreateInfo {
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert_module,
			pName = "main",
			pSpecializationInfo = spec,
		},
	)

	frag_module: vk.ShaderModule
	if desc.frag_spv != nil {
		frag_module = create_shader_module(desc.frag_spv)
		append(
			&stages,
			vk.PipelineShaderStageCreateInfo {
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = frag_module,
				pName = "main",
				pSpecializationInfo = spec,
			},
		)
	}
	defer if desc.frag_spv != nil do vk.DestroyShaderModule(g.device, frag_module, nil)

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = u32(len(desc.bindings)),
		pVertexBindingDescriptions      = raw_data(desc.bindings),
		vertexAttributeDescriptionCount = u32(len(desc.attributes)),
		pVertexAttributeDescriptions    = raw_data(desc.attributes),
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	// counts must be set even though the values come from vkCmdSet* at draw time
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	// COUNTER_CLOCKWISE throughout: bake_world emits every face wound so that
	// cross(p1-p0, p2-p0) points along the outward normal (verify_winding checks
	// this on every triangle), and the box mesh follows the same rule.
	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType           = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode     = .FILL,
		cullMode        = cull_flags(desc.cull),
		frontFace       = .COUNTER_CLOCKWISE,
		depthBiasEnable = b32(desc.depth_bias),
		lineWidth       = 1.0,
	}

	samples := desc.samples
	if samples == {} do samples = {._1}

	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = samples,
		minSampleShading     = 1.0,
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = desc.no_color_write ? {} : {.R, .G, .B, .A},
	}
	if desc.blend == .Alpha {
		color_blend_attachment.blendEnable = true
		color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attachment.colorBlendOp = .ADD
		color_blend_attachment.srcAlphaBlendFactor = .ONE
		color_blend_attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attachment.alphaBlendOp = .ADD
	}
	if desc.blend == .Premultiplied {
		color_blend_attachment.blendEnable = true
		color_blend_attachment.srcColorBlendFactor = .ONE
		color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attachment.colorBlendOp = .ADD
		color_blend_attachment.srcAlphaBlendFactor = .ONE
		color_blend_attachment.dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA
		color_blend_attachment.alphaBlendOp = .ADD
	}
	if desc.blend == .Additive {
		color_blend_attachment.blendEnable = true
		color_blend_attachment.srcColorBlendFactor = .ONE
		color_blend_attachment.dstColorBlendFactor = .ONE
		color_blend_attachment.colorBlendOp = .ADD
		color_blend_attachment.srcAlphaBlendFactor = .ONE
		color_blend_attachment.dstAlphaBlendFactor = .ONE
		color_blend_attachment.alphaBlendOp = .ADD
	}

	color_blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = u32(len(desc.color_formats)),
		pAttachments    = &color_blend_attachment,
	}

	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = b32(desc.depth_test != .Disabled),
		depthWriteEnable = b32(!desc.no_depth_write),
		depthCompareOp   = compare_op(desc.depth_test),
		minDepthBounds   = 0,
		maxDepthBounds   = 1,
	}

	dynamic_states := make([dynamic]vk.DynamicState, 0, 4, context.temp_allocator)
	append(&dynamic_states, vk.DynamicState.VIEWPORT, vk.DynamicState.SCISSOR)
	if desc.depth_bias do append(&dynamic_states, vk.DynamicState.DEPTH_BIAS)
	for state in desc.extra_dynamic do append(&dynamic_states, state)

	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	layout_ci := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = u32(len(desc.set_layouts)),
		pSetLayouts            = raw_data(desc.set_layouts),
		pushConstantRangeCount = u32(len(desc.push_constants)),
		pPushConstantRanges    = raw_data(desc.push_constants),
	}
	vk_check(vk.CreatePipelineLayout(g.device, &layout_ci, nil, &result.layout))

	// replaces the render pass: tells the pipeline which formats it renders to
	rendering_ci := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = u32(len(desc.color_formats)),
		pColorAttachmentFormats = raw_data(desc.color_formats),
		depthAttachmentFormat   = desc.depth_format,
	}

	pipeline_ci := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_ci,
		stageCount          = u32(len(stages)),
		pStages             = raw_data(stages),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterization,
		pMultisampleState   = &multisample,
		pDepthStencilState  = &depth_stencil,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dynamic_state,
		layout              = result.layout,
		renderPass          = {},
	}

	vk_check(
		vk.CreateGraphicsPipelines(
			g.device,
			pipeline_cache,
			1,
			&pipeline_ci,
			nil,
			&result.pipeline,
		),
	)

	live_pipelines += 1
	log.infof("Pipeline: {}", desc.name)
	return result
}

// Compiling the six pipelines from scratch costs a second or two on a slow CPU
// with an old driver. That is tolerable once at startup and not at all when a
// settings change rebuilds all of them, so the driver's own compilation results
// are kept between runs.
pipeline_cache: vk.PipelineCache

create_pipeline_cache :: proc() {
	data, err := os.read_entire_file(pipeline_cache_path(), context.temp_allocator)

	// The driver is required to reject a cache it does not recognise, but a
	// truncated file has crashed drivers before, so the header is checked here
	// rather than trusted.
	if err != nil || len(data) < size_of(vk.PipelineCacheHeaderVersionOne) {
		data = nil
	}

	cache_ci := vk.PipelineCacheCreateInfo {
		sType           = .PIPELINE_CACHE_CREATE_INFO,
		initialDataSize = len(data),
		pInitialData    = raw_data(data),
	}
	vk_check(vk.CreatePipelineCache(g.device, &cache_ci, nil, &pipeline_cache))
}

destroy_pipeline_cache :: proc() {
	size: int
	if vk.GetPipelineCacheData(g.device, pipeline_cache, &size, nil) == .SUCCESS && size > 0 {
		data := make([]byte, size, context.temp_allocator)
		if vk.GetPipelineCacheData(g.device, pipeline_cache, &size, raw_data(data)) == .SUCCESS {
			path := pipeline_cache_path()
			dir := path[:strings.last_index_byte(path, '/')]
			if os.exists(dir) || os.make_directory(dir) == nil {
				_ = os.write_entire_file(path, data)
			}
		}
	}
	vk.DestroyPipelineCache(g.device, pipeline_cache, nil)
}

@(private = "file")
pipeline_cache_path :: proc() -> string {
	dir := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if dir == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return "pipeline.cache"
		dir = fmt.tprintf("%s/.cache", home)
	}
	return fmt.tprintf("%s/dust2/pipeline.cache", dir)
}

// Pipelines outstanding right now. destroy_all_pipelines names every one by
// hand, and a new pipeline added to create_all_pipelines but forgotten there
// leaks silently -- once per settings change, and once more at exit, where the
// validation layer finally reports it as a pile of handles with no hint as to
// which renderer they belong to.
//
// Counting them turns that into a warning at the moment the list goes out of
// date, naming the count, while the change that caused it is still on screen.
@(private = "file")
live_pipelines: int

destroy_pipeline :: proc(p: Pipeline) {
	// Destroying a zero handle is legal and several call sites rely on it, so
	// only real ones count.
	if p.pipeline != 0 do live_pipelines -= 1
	vk.DestroyPipeline(g.device, p.pipeline, nil)
	vk.DestroyPipelineLayout(g.device, p.layout, nil)
}

// Called after destroy_all_pipelines. Anything left is a pipeline that exists
// and that nothing will ever free.
check_pipelines_released :: proc() {
	if live_pipelines == 0 do return
	log.warnf(
		"{} pipeline(s) created but never destroyed -- destroy_all_pipelines is missing an entry",
		live_pipelines,
	)
	// Reset, so a second rebuild reports its own delta rather than repeating
	// this one on top of it.
	live_pipelines = 0
}
