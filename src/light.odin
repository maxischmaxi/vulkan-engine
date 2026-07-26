package main

import "core:log"
import "core:math/linalg"
import vk "vendor:vulkan"

// std430 gives vec3 a 16-byte alignment, which this field order satisfies
// exactly -- position and colour both land on a multiple of 16.
Point_Light :: struct {
	position:  [3]f32,
	radius:    f32, // distance at which the contribution reaches zero
	color:     [3]f32,
	intensity: f32,
}

#assert(size_of(Point_Light) == 32)
#assert(offset_of(Point_Light, color) == 16)

// The sun. Direction is where the light travels, so it points down.
Directional_Light :: struct {
	direction: [3]f32,
	color:     [3]f32,
	intensity: f32,
}

MAX_POINT_LIGHTS :: 64

sun := Directional_Light {
	direction = {-0.45, -0.35, -0.82},
	color     = {1.0, 0.94, 0.82}, // midday sun, slightly warm
	intensity = 3.2,
}

// Hemisphere ambient stands in for bounced light: sky colour from above,
// sand-tinted bounce from below. Far cheaper than an irradiance probe and
// enough to keep shadowed surfaces from going flat black.
//
// The ratio to the sun is what decides whether shadows read as shadows or as
// holes. Physically the midday sky is far dimmer than the sun, but rendering
// it that way leaves anything out of direct light unreadable, so this sits
// around 5:1 rather than the 20:1 the real world manages.
ambient_sky := [3]f32{0.40, 0.50, 0.66}
ambient_ground := [3]f32{0.34, 0.28, 0.20}
ambient_intensity: f32 = 1.3

exposure: f32 = 1.0

point_lights: [dynamic]Point_Light

// Warm fill inside the places the sun cannot reach. Radius is what actually
// bounds the cost, so it stays as tight as the space allows.
init_lights :: proc() {
	point_lights = make([dynamic]Point_Light, 0, MAX_POINT_LIGHTS)

	lamp :: proc(x, y, z: f32, radius: f32 = 12, intensity: f32 = 8) -> Point_Light {
		return {
			position = {x, y, z},
			radius = radius,
			color = {1.0, 0.78, 0.52}, // tungsten
			intensity = intensity,
		}
	}

	// tunnels, the longest stretch with no sky above it
	append(&point_lights, lamp(-35, -30, 3.6))
	append(&point_lights, lamp(-35, -14, 3.6))
	append(&point_lights, lamp(-35, 2, 3.6))
	append(&point_lights, lamp(-35, 16, 4.8))

	// mid doors and the approach either side
	append(&point_lights, lamp(0, -1, 4.2, 14, 10))
	append(&point_lights, lamp(0, -18, 4.2))
	append(&point_lights, lamp(0, 16, 4.2))

	// long doors
	append(&point_lights, lamp(34, -20, 4.2, 14, 10))
	append(&point_lights, lamp(34, -30, 4.2))

	// catwalk underside
	append(&point_lights, lamp(19, 12, 4.2))

	// bombsites, cooler so they read as open sky
	site :: proc(x, y: f32) -> Point_Light {
		return {position = {x, y, 5.0}, radius = 20, color = {0.72, 0.82, 1.0}, intensity = 5}
	}
	append(&point_lights, site(-32, 36))
	append(&point_lights, site(32, 34))

	if len(point_lights) > MAX_POINT_LIGHTS {
		log.panicf("{} point lights exceeds the buffer's {}", len(point_lights), MAX_POINT_LIGHTS)
	}
	log.infof("Lights: 1 directional (shadowed), {} point", len(point_lights))
}

// Sized for the maximum so lights can be added at runtime without reallocating
// and rewriting descriptors.
create_light_buffer :: proc() {
	size := vk.DeviceSize(MAX_POINT_LIGHTS * size_of(Point_Light))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		g.light_buffers[i], g.light_memories[i] = create_buffer(
			size,
			{.STORAGE_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(vk.MapMemory(g.device, g.light_memories[i], 0, size, {}, &g.light_mapped[i]))
	}
}

destroy_light_buffer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, g.light_memories[i])
		destroy_buffer(g.light_buffers[i], g.light_memories[i])
	}
	delete(point_lights)
}

update_light_buffer :: proc(frame: u32) {
	if len(point_lights) == 0 do return
	dst := ([^]Point_Light)(g.light_mapped[frame])
	copy(dst[:len(point_lights)], point_lights[:])
}

sun_direction_normalized :: proc() -> [3]f32 {
	return linalg.normalize(sun.direction)
}
