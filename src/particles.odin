package main

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "game"
import vk "vendor:vulkan"

// The particle pool: everything that is drawn as a camera-facing sprite and
// dies of old age. Explosions, smoke, sparks, dust.
//
// Purely cosmetic, and deliberately so. Nothing here is simulated on the server
// or predicted against it -- a particle cannot block a sight line, cannot be
// stood in and cannot be shot. What blocks and burns is game/zone.odin on both
// ends of the wire; this only has to look like the thing that does.
//
// A fixed pool with ring allocation, like the tracers and the decals. It never
// grows and never panics: at the ceiling the oldest particle is overwritten,
// which costs the tail of one puff and is invisible next to a frame that
// stalled to allocate.

MAX_PARTICLES :: 2048

// One quad per particle, so the vertex buffer is a single unit quad and the
// pool goes down the instance stream.
Particle_Look :: enum u8 {
	Soft, // smoke, dust: alpha blended
	Fire, // additive, tonemapped, saturates toward white
	Spark, // additive, stretched along its own velocity
}

// KEEP IN SYNC with the LOOK_ constants in shaders/particle.frag.

Particle :: struct {
	position:   [3]f32,
	velocity:   [3]f32,
	// Exponential, per second: 0 keeps a particle's speed, high numbers stop it
	// almost at once. What makes a fireball punch out and then hang there.
	drag:       f32,
	// A multiple of world gravity. Smoke rises (negative), sparks fall (1).
	gravity:    f32,
	size_from:  f32,
	size_to:    f32,
	color_from: [4]f32, // rgb, opacity
	color_to:   [4]f32,
	age:        f32,
	life:       f32,
	look:       Particle_Look,
	seed:       f32,
	active:     bool,
}

Particle_Instance :: struct {
	center_size: [4]f32,
	color:       [4]f32,
	params:      [4]f32, // look, seed, age 0..1, stretch
	axis:        [4]f32, // world direction to stretch along
}

#assert(size_of(Particle_Instance) == 64)

Particle_Vertex :: struct {
	corner: [2]f32,
}

Particle_Renderer :: struct {
	vertex_buffer:     vk.Buffer,
	vertex_memory:     vk.DeviceMemory,
	index_buffer:      vk.Buffer,
	index_memory:      vk.DeviceMemory,
	instance_buffers:  [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	instance_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	instance_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,
	alpha_pipeline:    Pipeline,
	additive_pipeline: Pipeline,
	pool:              [MAX_PARTICLES]Particle,
	next:              int, // ring cursor; anything it overwrites has had its run
	// Built every frame, alpha first then additive, so the two draws are two
	// ranges of one buffer rather than two buffers.
	instances:         [MAX_PARTICLES]Particle_Instance,
	alpha_count:       int,
	additive_count:    int,
	// Self-seeded: nothing about a particle reaches the wire, so this must
	// never draw from the simulation's generator.
	rng_state:         rand.Default_Random_State,
	rng:               rand.Generator,
}

particles: Particle_Renderer

// How many of the pool the current graphics preset allows. The whole cost of a
// particle is fill rate, which is exactly what a weak GPU has least of.
particle_budget :: proc() -> int {
	return min(int(settings.particles), MAX_PARTICLES)
}

init_particles :: proc() {
	particles.rng = rand.default_random_generator(&particles.rng_state)
	clear_particles()
}

clear_particles :: proc() {
	for &p in particles.pool do p.active = false
	particles.next = 0
	particles.alpha_count = 0
	particles.additive_count = 0
}

// The one way a particle comes into the world. `life` at or below zero is a
// no-op rather than an immortal particle.
spawn_particle :: proc(p: Particle) {
	if p.life <= 0 do return
	budget := particle_budget()
	if budget <= 0 do return

	slot := &particles.pool[particles.next % budget]
	particles.next = (particles.next + 1) % budget
	slot^ = p
	slot.age = 0
	slot.active = true
	slot.seed = rand.float32(particles.rng)
}

// A random direction inside a cone around `axis`. `spread` is the half angle in
// degrees; 180 is the whole sphere, which is what a blast wants.
particle_cone :: proc(axis: [3]f32, spread: f32) -> [3]f32 {
	// Uniform on the spherical cap: cos is what has to be uniform, not the
	// angle, or every burst clusters around its own rim.
	cos_max := math.cos(math.to_radians(clamp(spread, 0, 180)))
	z := rand.float32_range(cos_max, 1, particles.rng)
	radius := math.sqrt(max(1 - z * z, 0))
	phi := rand.float32_range(0, math.TAU, particles.rng)

	// Any basis around the axis will do; the roll is randomised anyway.
	up := abs(axis.z) > 0.9 ? [3]f32{1, 0, 0} : [3]f32{0, 0, 1}
	forward := linalg.normalize(axis)
	right := linalg.normalize(linalg.cross(up, forward))
	local_up := linalg.cross(forward, right)

	return forward * z + right * (radius * math.cos(phi)) + local_up * (radius * math.sin(phi))
}

particle_random :: proc(low, high: f32) -> f32 {
	return rand.float32_range(low, high, particles.rng)
}

// Ages the pool and builds this frame's instances. Runs after the camera has
// settled, like the tracers: the quads are spanned around the eye they will be
// seen through.
update_particles :: proc(dt: f32) {
	particles.alpha_count = 0
	particles.additive_count = 0
	if dt <= 0 do return

	// Alpha instances grow from the front, additive ones from the back, so one
	// pass over the pool sorts them into the two draws without a second buffer
	// or a sort.
	additive_cursor := len(particles.instances)

	for &p in particles.pool {
		if !p.active do continue

		p.age += dt
		if p.age >= p.life {
			p.active = false
			continue
		}

		// Exponential drag, so a burst punches out and settles rather than
		// coasting forever or stopping dead.
		if p.drag > 0 {
			p.velocity *= math.exp(-p.drag * dt)
		}
		p.velocity.z -= game.GRAVITY * p.gravity * dt
		p.position += p.velocity * dt

		t := p.age / p.life
		instance := Particle_Instance {
			center_size = {
				p.position.x,
				p.position.y,
				p.position.z,
				math.lerp(p.size_from, p.size_to, t) * 0.5,
			},
			color = linalg.lerp(p.color_from, p.color_to, t),
			params = {f32(p.look), p.seed, t, 1},
		}

		if p.look == .Spark {
			speed := linalg.length(p.velocity)
			if speed > 0.01 {
				direction := p.velocity / speed
				instance.axis = {direction.x, direction.y, direction.z, 0}
				// The faster it flies the longer the streak, capped so a spark
				// out of a point-blank blast is not a metre-long bar.
				instance.params.w = clamp(speed * 0.35, 1.5, 7)
			}
		}

		if p.look == .Soft {
			particles.instances[particles.alpha_count] = instance
			particles.alpha_count += 1
		} else {
			additive_cursor -= 1
			particles.instances[additive_cursor] = instance
			particles.additive_count += 1
		}

		// The two ends met: the rest of this frame's particles are dropped, not
		// the frames after it. Cannot happen while the pool and the instance
		// array are the same size, and stays as the guard that says so.
		if particles.alpha_count >= additive_cursor do break
	}
}

// ------------------------------------------------------------------ rendering

particle_binding_descriptions :: proc() -> [2]vk.VertexInputBindingDescription {
	return {
		{binding = 0, stride = size_of(Particle_Vertex), inputRate = .VERTEX},
		{binding = 1, stride = size_of(Particle_Instance), inputRate = .INSTANCE},
	}
}

particle_attribute_descriptions :: proc() -> [5]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = 0},
		{
			location = 1,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle_Instance, center_size)),
		},
		{
			location = 2,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle_Instance, color)),
		},
		{
			location = 3,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle_Instance, params)),
		},
		{
			location = 4,
			binding = 1,
			format = .R32G32B32A32_SFLOAT,
			offset = u32(offset_of(Particle_Instance, axis)),
		},
	}
}

create_particle_renderer :: proc() {
	corners := [4]Particle_Vertex{{{-1, -1}}, {{1, -1}}, {{1, 1}}, {{-1, 1}}}
	indices := [6]u32{0, 1, 2, 0, 2, 3}

	particles.vertex_buffer, particles.vertex_memory = create_device_local_buffer(
		corners[:],
		{.VERTEX_BUFFER},
	)
	particles.index_buffer, particles.index_memory = create_device_local_buffer(
		indices[:],
		{.INDEX_BUFFER},
	)

	size := vk.DeviceSize(MAX_PARTICLES * size_of(Particle_Instance))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		particles.instance_buffers[i], particles.instance_memories[i] = create_buffer(
			size,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		vk_check(
			vk.MapMemory(
				g.device,
				particles.instance_memories[i],
				0,
				size,
				{},
				&particles.instance_mapped[i],
			),
		)
	}
}

create_particle_pipelines :: proc() {
	bindings := particle_binding_descriptions()
	attributes := particle_attribute_descriptions()

	desc := Pipeline_Desc {
		name           = "particles (alpha)",
		vert_spv       = PARTICLE_VERT_CODE,
		frag_spv       = PARTICLE_FRAG_CODE,
		bindings       = bindings[:],
		attributes     = attributes[:],
		set_layouts    = {descriptors.frame_layout},
		color_formats  = {g.swapchain_format},
		depth_format   = g.depth_format,
		samples        = g.msaa_samples,
		// Behind a wall means invisible, but a particle occludes nothing:
		// test depth, never write it.
		depth_test     = .Nearer,
		no_depth_write = true,
		blend          = .Alpha,
		// a camera-facing quad has no meaningful winding
		cull           = .None,
		spec           = shadow_spec_constants(),
	}
	particles.alpha_pipeline = build_pipeline(desc)

	desc.name = "particles (additive)"
	desc.blend = .Additive
	particles.additive_pipeline = build_pipeline(desc)
}

destroy_particle_renderer :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(g.device, particles.instance_memories[i])
		destroy_buffer(particles.instance_buffers[i], particles.instance_memories[i])
	}
	destroy_buffer(particles.vertex_buffer, particles.vertex_memory)
	destroy_buffer(particles.index_buffer, particles.index_memory)
}

upload_particles :: proc(frame: u32) {
	if particles.alpha_count > 0 {
		mem.copy(
			particles.instance_mapped[frame],
			raw_data(&particles.instances),
			particles.alpha_count * size_of(Particle_Instance),
		)
	}
	if particles.additive_count > 0 {
		// The additive block sits at the far end of the array, where
		// update_particles built it.
		first := len(particles.instances) - particles.additive_count
		dst := ([^]Particle_Instance)(particles.instance_mapped[frame])
		mem.copy(
			&dst[first],
			&particles.instances[first],
			particles.additive_count * size_of(Particle_Instance),
		)
	}
}

record_particle_pass :: proc(cmd: vk.CommandBuffer, frame: u32) {
	if particles.alpha_count == 0 && particles.additive_count == 0 do return

	buffers := [2]vk.Buffer{particles.vertex_buffer, particles.instance_buffers[frame]}
	offsets := [2]vk.DeviceSize{0, 0}

	draw :: proc(cmd: vk.CommandBuffer, frame: u32, pipeline: Pipeline, first, count: int) {
		if count == 0 do return
		vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline.pipeline)
		bind_frame_set(cmd, pipeline.layout, frame)
		vk.CmdDrawIndexed(cmd, 6, u32(count), 0, 0, u32(first))
	}

	vk.CmdBindVertexBuffers(cmd, 0, 2, raw_data(&buffers), raw_data(&offsets))
	vk.CmdBindIndexBuffer(cmd, particles.index_buffer, 0, .UINT32)

	// Smoke first, then the light on top of it: an additive spark behind a puff
	// of its own blast should still show through, and the other order paints
	// the puff over the spark.
	draw(cmd, frame, particles.alpha_pipeline, 0, particles.alpha_count)
	draw(
		cmd,
		frame,
		particles.additive_pipeline,
		len(particles.instances) - particles.additive_count,
		particles.additive_count,
	)
}
