package main

import "core:log"
import "core:mem"
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

Depth_Test :: enum {
	Less, // zero value
	Less_Equal,
	Always,
	Disabled,
}

Blend_Mode :: enum {
	Opaque, // zero value
	Alpha,
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
	blend:          Blend_Mode,
	depth_bias:     bool,
	extra_dynamic:  []vk.DynamicState,
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
	case .Less:
		return .LESS
	case .Less_Equal:
		return .LESS_OR_EQUAL
	case .Always, .Disabled:
		return .ALWAYS
	}
	return .LESS
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

	stages := make([dynamic]vk.PipelineShaderStageCreateInfo, 0, 2, context.temp_allocator)
	append(
		&stages,
		vk.PipelineShaderStageCreateInfo {
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert_module,
			pName = "main",
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
		colorWriteMask = {.R, .G, .B, .A},
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

	vk_check(vk.CreateGraphicsPipelines(g.device, {}, 1, &pipeline_ci, nil, &result.pipeline))

	log.infof("Pipeline: {}", desc.name)
	return result
}

destroy_pipeline :: proc(p: Pipeline) {
	vk.DestroyPipeline(g.device, p.pipeline, nil)
	vk.DestroyPipelineLayout(g.device, p.layout, nil)
}
