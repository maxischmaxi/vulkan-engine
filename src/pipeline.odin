package main

import "core:log"
import "core:mem"
import vk "vendor:vulkan"

VERT_CODE :: #load("../shaders/triangle.vert.spv")
FRAG_CODE :: #load("../shaders/triangle.frag.spv")

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

create_graphics_pipeline :: proc() {
	vert_module := create_shader_module(VERT_CODE)
	defer vk.DestroyShaderModule(g.device, vert_module, nil)

	frag_module := create_shader_module(FRAG_CODE)
	defer vk.DestroyShaderModule(g.device, frag_module, nil)

	stages := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert_module,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag_module,
			pName = "main",
		},
	}

	binding_desc := vertex_binding_description()
	attr_descs := vertex_attribute_descriptions()

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding_desc,
		vertexAttributeDescriptionCount = u32(len(attr_descs)),
		pVertexAttributeDescriptions    = raw_data(&attr_descs),
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

	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1.0,
	}

	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
		minSampleShading     = 1.0,
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable    = false,
		colorWriteMask = {.R, .G, .B, .A},
	}

	color_blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	// LESS keeps the fragment closest to the camera; writes feed later draws
	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS,
		depthBoundsTestEnable = false,
		stencilTestEnable     = false,
		minDepthBounds        = 0,
		maxDepthBounds        = 1,
	}

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	push_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(PushConstants),
	}

	layout_ci := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &g.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_range,
	}
	vk_check(vk.CreatePipelineLayout(g.device, &layout_ci, nil, &g.pipeline_layout))

	// replaces the render pass: tells the pipeline which formats it renders to
	color_formats := []vk.Format{g.swapchain_format}
	rendering_ci := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = raw_data(color_formats),
		depthAttachmentFormat   = g.depth_format,
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
		layout              = g.pipeline_layout,
		renderPass          = {},
	}

	vk_check(vk.CreateGraphicsPipelines(g.device, {}, 1, &pipeline_ci, nil, &g.graphics_pipeline))

	log.info("Graphics pipeline created")
}

destroy_graphics_pipeline :: proc() {
	vk.DestroyPipeline(g.device, g.graphics_pipeline, nil)
	vk.DestroyPipelineLayout(g.device, g.pipeline_layout, nil)
}

