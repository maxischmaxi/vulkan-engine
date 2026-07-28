package main

// Every compiled shader in one place. Adding a pipeline means adding a line
// here and a Pipeline_Desc wherever that pipeline belongs -- nothing else in the
// renderer needs to know about it.
//
// `just shaders` compiles these; the build fails loudly if one is missing rather
// than silently linking a stale blob.

WORLD_VERT_CODE :: #load("../shaders/world.vert.spv")
WORLD_FRAG_CODE :: #load("../shaders/world.frag.spv")
PREPASS_VERT_CODE :: #load("../shaders/prepass.vert.spv")
OVERDRAW_FRAG_CODE :: #load("../shaders/overdraw.frag.spv")

SHADOW_VERT_CODE :: #load("../shaders/shadow.vert.spv")
SHADOW_PROP_VERT_CODE :: #load("../shaders/shadow_prop.vert.spv")
SHADOW_MODEL_VERT_CODE :: #load("../shaders/shadow_model.vert.spv")

// Imported meshes share world.frag; only the vertex stage differs.
MODEL_VERT_CODE :: #load("../shaders/model.vert.spv")

PROP_VERT_CODE :: #load("../shaders/prop.vert.spv")
PROP_FRAG_CODE :: #load("../shaders/prop.frag.spv")

DECAL_VERT_CODE :: #load("../shaders/decal.vert.spv")
DECAL_FRAG_CODE :: #load("../shaders/decal.frag.spv")

CROSSHAIR_VERT_CODE :: #load("../shaders/crosshair.vert.spv")
CROSSHAIR_FRAG_CODE :: #load("../shaders/crosshair.frag.spv")

HUD_QUAD_VERT_CODE :: #load("../shaders/hud_quad.vert.spv")
HUD_QUAD_FRAG_CODE :: #load("../shaders/hud_quad.frag.spv")
