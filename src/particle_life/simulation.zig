// Particle Life - Main Simulation Orchestrator
//
// Manages particle system state, buffers, and simulation execution

const std = @import("std");
const particle = @import("particle.zig");
const system = @import("system.zig");
const shaders = @import("shaders.zig");
const physics = @import("physics.zig");
const spatial = @import("spatial.zig");
const buffer = @import("../webgpu/buffer.zig");
const shader = @import("../webgpu/shader.zig");
const pipeline = @import("../webgpu/pipeline.zig");
const compute = @import("../webgpu/compute.zig");
const handles = @import("../webgpu/handles.zig");
const device = @import("../webgpu/device.zig");
const texture = @import("../webgpu/texture.zig");
const webinputs = @import("../webutils/webinputs.zig");

/// Main particle simulation state
pub const Simulation = struct {
    particle_count: u32,
    species_count: u32,
    sim_width: f32,
    sim_height: f32,
    sim_depth: f32,

    // GPU buffers
    particle_buffer: buffer.Buffer,
    species_buffer: buffer.Buffer,
    force_buffer: buffer.Buffer,
    options_buffer: buffer.Buffer,
    camera_buffer: buffer.Buffer,

    // HDR render targets
    hdr_texture: texture.Texture,
    hdr_texture_view: texture.TextureView,
    blue_noise_texture_view: ?handles.TextureViewHandle = null,
    canvas_width: u32,
    canvas_height: u32,

    // Particle render pipelines (HDR)
    glow_shader: shader.ShaderModule,
    circle_shader: shader.ShaderModule,
    point_shader: shader.ShaderModule,
    particle_bind_group_layout: pipeline.BindGroupLayout,
    camera_bind_group_layout: pipeline.BindGroupLayout,
    particle_bind_group: pipeline.BindGroup,
    camera_bind_group: pipeline.BindGroup,
    glow_pipeline: handles.RenderPipelineHandle,
    circle_pipeline: handles.RenderPipelineHandle,
    point_pipeline: handles.RenderPipelineHandle,

    // Compose pipeline (HDR → Screen)
    compose_shader: shader.ShaderModule,
    compose_pipeline: handles.RenderPipelineHandle,
    compose_bind_group_layout: pipeline.BindGroupLayout,
    compose_bind_group: pipeline.BindGroup,

    // Legacy (will be removed)
    render_shader: shader.ShaderModule,
    render_pipeline_handle: handles.RenderPipelineHandle,

    // Physics pipelines
    physics_pipeline: physics.Physics,
    spatial_pipeline: spatial.SpatialPipeline,
    use_spatial_optimization: bool,
    max_force_radius: f32,

    // Init pipeline
    init_shader: shader.ShaderModule,
    init_pipeline: pipeline.ComputePipeline,
    init_seed_buffer: buffer.Buffer,
    init_bind_group_particles: pipeline.BindGroup,
    init_bind_group_options: pipeline.BindGroup,
    init_bind_group_seed: pipeline.BindGroup,

    // Simulation state
    rng: system.Rng,
    options: particle.SimulationOptions,
    camera: particle.CameraParams,
    symmetric_forces: bool,
    friction_coefficient: f32,

    pub fn init(
        particle_count: u32,
        species_count: u32,
        sim_width: f32,
        sim_height: f32,
        sim_depth: f32,
        seed: u32,
        symmetric_forces: bool,
        friction_coefficient: f32,
    ) !Simulation {
        var sim = Simulation{
            .particle_count = particle_count,
            .species_count = species_count,
            .sim_width = sim_width,
            .sim_height = sim_height,
            .sim_depth = sim_depth,
            .rng = system.Rng.init(seed),
            .options = particle.SimulationOptions.init(sim_width, sim_height, sim_depth, species_count),
            .camera = particle.CameraParams.initForSimulation(1024.0, 768.0, sim_width, sim_height, sim_depth), // Will be updated on resize
            .symmetric_forces = symmetric_forces,
            .friction_coefficient = friction_coefficient,
            .particle_buffer = undefined,
            .species_buffer = undefined,
            .force_buffer = undefined,
            .options_buffer = undefined,
            .camera_buffer = undefined,
            .hdr_texture = undefined,
            .hdr_texture_view = undefined,
            .canvas_width = 1024,
            .canvas_height = 768,
            .glow_shader = undefined,
            .circle_shader = undefined,
            .point_shader = undefined,
            .particle_bind_group_layout = undefined,
            .camera_bind_group_layout = undefined,
            .particle_bind_group = undefined,
            .camera_bind_group = undefined,
            .glow_pipeline = handles.RenderPipelineHandle.invalid(),
            .circle_pipeline = handles.RenderPipelineHandle.invalid(),
            .point_pipeline = handles.RenderPipelineHandle.invalid(),
            .compose_shader = undefined,
            .compose_pipeline = handles.RenderPipelineHandle.invalid(),
            .compose_bind_group_layout = undefined,
            .compose_bind_group = undefined,
            .render_shader = undefined,
            .render_pipeline_handle = handles.RenderPipelineHandle.invalid(),
            .physics_pipeline = undefined,
            .spatial_pipeline = undefined,
            .use_spatial_optimization = true, // Use optimized spatial algorithm
            .max_force_radius = 80.0, // Maximum force radius (for binning)
            .init_shader = undefined,
            .init_pipeline = undefined,
            .init_seed_buffer = undefined,
            .init_bind_group_particles = undefined,
            .init_bind_group_options = undefined,
            .init_bind_group_seed = undefined,
        };

        // Create GPU buffers
        sim.particle_buffer = buffer.createStorageBuffer(@sizeOf(particle.Particle) * particle_count);
        sim.species_buffer = buffer.createStorageBuffer(@sizeOf(particle.Species) * species_count);
        sim.force_buffer = buffer.createStorageBuffer(@sizeOf(particle.Force) * species_count * species_count);
        sim.options_buffer = buffer.createUniformBuffer(@sizeOf(particle.SimulationOptions));
        sim.camera_buffer = buffer.createUniformBuffer(@sizeOf(particle.CameraParams));
        sim.init_seed_buffer = buffer.createUniformBuffer(4); // u32 seed

        // Sync bin size with max force radius to ensure grid consistency
        sim.options.bin_size = sim.max_force_radius;

        // Set up init pipeline
        try sim.setupInitPipeline();

        // Generate and upload initial system
        try sim.generateSystem();

        // Set up render pipeline
        try sim.setupRenderPipeline();

        // Set up physics pipeline (basic, for fallback)
        sim.physics_pipeline = try physics.Physics.init(sim.particle_buffer, sim.options_buffer);

        // Set up spatial optimization pipeline (the real deal!)
        // Note: SpatialPipeline might need updates to handle Z dimension too if it uses grid size
        sim.spatial_pipeline = try spatial.SpatialPipeline.init(
            sim.particle_buffer,
            particle_count,
            sim.species_buffer,
            sim.force_buffer,
            sim.options_buffer,
            sim_width,
            sim_height,
            sim.sim_depth,
            sim.max_force_radius,
        );

        return sim;
    }

    pub fn generateSystem(self: *Simulation) !void {
        // see build.zig for stack size IMPORTANT
        const MAX_SPECIES = 16;

        const actual_species_count = @min(self.species_count, MAX_SPECIES);

        var species: [MAX_SPECIES]particle.Species = undefined;
        var forces: [MAX_SPECIES * MAX_SPECIES]particle.Force = undefined;

        log("Generating particles (GPU)...");

        // Upload options first (needed for boundaries)
        self.options_buffer.writeTyped(particle.SimulationOptions, 0, &[_]particle.SimulationOptions{self.options});
        
        // Upload seed
        // Simple LCG on CPU to get a fresh seed for the GPU hasher
        const seed = @as(u32, @intFromFloat(self.rng.next() * 4294967296.0));
        self.init_seed_buffer.writeTyped(u32, 0, &[_]u32{seed});

        // Dispatch Init Shader
        const encoder = compute.CommandEncoder.create();
        const pass = encoder.beginComputePass();
        pass.setPipeline(self.init_pipeline);
        pass.setBindGroup(0, self.init_bind_group_particles);
        pass.setBindGroup(1, self.init_bind_group_options);
        pass.setBindGroup(2, self.init_bind_group_seed);
        
        const workgroup_count = (self.particle_count + 63) / 64;
        pass.dispatch(workgroup_count, 1, 1);
        pass.end();
        
        const cmd_buffer = encoder.finish();
        cmd_buffer.submit();

        log("Generating species colors...");
        system.generateSpeciesColors(species[0..actual_species_count], &self.rng);

        log("Generating force matrix...");
        const force_count = @as(usize, actual_species_count) * @as(usize, actual_species_count);
        system.generateForceMatrix(forces[0..force_count], actual_species_count, &self.rng, self.symmetric_forces);

        log("Uploading species/forces to GPU...");

        // Upload to GPU
        self.species_buffer.writeTyped(particle.Species, 0, species[0..actual_species_count]);
        self.force_buffer.writeTyped(particle.Force, 0, forces[0..force_count]);
        self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});

        log("Particle system generated:");
        logInt("  Particles:", self.particle_count);
        logInt("  Species:", actual_species_count);
    }

    fn setupInitPipeline(self: *Simulation) !void {
        log("Setting up Init pipeline...");

        self.init_shader = shader.ShaderModule.create(shaders.particle_init);
        if (!self.init_shader.isValid()) {
            log("ERROR: Failed to create init shader");
            return error.ShaderCreationFailed;
        }

        // Layouts matching shader groups
        const entries_0 = [_]pipeline.BindGroupLayoutEntry{
            pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .storage),
        };
        const layout_0 = pipeline.BindGroupLayout.create(&entries_0);

        const entries_1 = [_]pipeline.BindGroupLayoutEntry{
            pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .uniform),
        };
        const layout_1 = pipeline.BindGroupLayout.create(&entries_1);

        const entries_2 = [_]pipeline.BindGroupLayoutEntry{
            pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .uniform),
        };
        const layout_2 = pipeline.BindGroupLayout.create(&entries_2);

        // Pipeline Layout
        const layouts = [_]pipeline.BindGroupLayout{layout_0, layout_1, layout_2};
        const pipeline_layout = pipeline.PipelineLayout.create(&layouts);

        self.init_pipeline = pipeline.ComputePipeline.create(pipeline_layout, self.init_shader, "initParticles");

        // Bind Groups
        const bg_entries_0 = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initFull(0, self.particle_buffer.handle, self.particle_buffer.size),
        };
        self.init_bind_group_particles = pipeline.BindGroup.create(layout_0, &bg_entries_0);

        const bg_entries_1 = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initFull(0, self.options_buffer.handle, self.options_buffer.size),
        };
        self.init_bind_group_options = pipeline.BindGroup.create(layout_1, &bg_entries_1);

        const bg_entries_2 = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initFull(0, self.init_seed_buffer.handle, self.init_seed_buffer.size),
        };
        self.init_bind_group_seed = pipeline.BindGroup.create(layout_2, &bg_entries_2);

        log("✓ Init pipeline created");
    }

    fn setupRenderPipeline(self: *Simulation) !void {
        log("Setting up HDR render pipeline...");

        // Create HDR texture for rendering
        self.hdr_texture = texture.createHDRTexture(self.canvas_width, self.canvas_height);
        if (!self.hdr_texture.isValid()) {
            log("ERROR: Failed to create HDR texture");
            return error.TextureCreationFailed;
        }
        self.hdr_texture_view = self.hdr_texture.createView();
        if (!self.hdr_texture_view.isValid()) {
            log("ERROR: Failed to create HDR texture view");
            return error.TextureViewCreationFailed;
        }
        log("✓ HDR texture created");

        // Create shader modules for HDR rendering
        self.glow_shader = shader.ShaderModule.create(shaders.particle_render_glow);
        if (!self.glow_shader.isValid()) {
            log("ERROR: Failed to create glow shader");
            return error.ShaderCreationFailed;
        }

        self.circle_shader = shader.ShaderModule.create(shaders.particle_render_circle);
        if (!self.circle_shader.isValid()) {
            log("ERROR: Failed to create circle shader");
            return error.ShaderCreationFailed;
        }

        self.point_shader = shader.ShaderModule.create(shaders.particle_render_point_hdr);
        if (!self.point_shader.isValid()) {
            log("ERROR: Failed to create point shader");
            return error.ShaderCreationFailed;
        }
        log("✓ HDR shaders created");

        // Create legacy shader for fallback (can remove later)
        self.render_shader = shader.ShaderModule.create(shaders.particle_render_point);

        // Create bind group layouts
        // Group 0: particles + species (storage buffers)
        const particle_layout_entries = [_]pipeline.BindGroupLayoutEntry{
            pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.VERTEX, .read_only_storage),
            pipeline.BindGroupLayoutEntry.init(1, pipeline.ShaderVisibility.VERTEX, .read_only_storage),
        };
        self.particle_bind_group_layout = pipeline.BindGroupLayout.create(&particle_layout_entries);

        // Group 1: camera (uniform buffer) - needs VERTEX + FRAGMENT visibility
        // (Fragment shaders use pixels_per_unit for anti-aliasing)
        const camera_layout_entries = [_]pipeline.BindGroupLayoutEntry{
            pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.VERTEX | pipeline.ShaderVisibility.FRAGMENT, .uniform),
        };
        self.camera_bind_group_layout = pipeline.BindGroupLayout.create(&camera_layout_entries);

        // Create bind groups
        const particle_bind_entries = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initFull(0, self.particle_buffer.handle, self.particle_buffer.size),
            pipeline.BindGroupEntry.initFull(1, self.species_buffer.handle, self.species_buffer.size),
        };
        self.particle_bind_group = pipeline.BindGroup.create(self.particle_bind_group_layout, &particle_bind_entries);

        const camera_bind_entries = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initFull(0, self.camera_buffer.handle, self.camera_buffer.size),
        };
        self.camera_bind_group = pipeline.BindGroup.create(self.camera_bind_group_layout, &camera_bind_entries);

        // Create pipeline layout (shared by all three pipelines)
        const layouts = [_]pipeline.BindGroupLayout{ self.particle_bind_group_layout, self.camera_bind_group_layout };
        const pipeline_layout = pipeline.PipelineLayout.create(&layouts);

        // Create HDR render pipelines (format 0 = rgba16float, blending enabled)
        log("Creating HDR render pipelines...");

        // Glow pipeline - always rendered first
        self.glow_pipeline.id = js_webgpu_create_render_pipeline_hdr(
            device.getDevice().id,
            pipeline_layout.handle.id,
            self.glow_shader.handle.id,
            "vertexGlow".ptr,
            "vertexGlow".len,
            "fragmentGlow".ptr,
            "fragmentGlow".len,
            0, // rgba16float
            1, // enable blending
        );
        if (!self.glow_pipeline.isValid()) {
            log("ERROR: Failed to create glow pipeline");
            return error.PipelineCreationFailed;
        }

        // Circle pipeline - used when zoomed in
        self.circle_pipeline.id = js_webgpu_create_render_pipeline_hdr(
            device.getDevice().id,
            pipeline_layout.handle.id,
            self.circle_shader.handle.id,
            "vertexCircle".ptr,
            "vertexCircle".len,
            "fragmentCircle".ptr,
            "fragmentCircle".len,
            0, // rgba16float
            1, // enable blending
        );
        if (!self.circle_pipeline.isValid()) {
            log("ERROR: Failed to create circle pipeline");
            return error.PipelineCreationFailed;
        }

        // Point pipeline - used when zoomed out
        self.point_pipeline.id = js_webgpu_create_render_pipeline_hdr(
            device.getDevice().id,
            pipeline_layout.handle.id,
            self.point_shader.handle.id,
            "vertexPoint".ptr,
            "vertexPoint".len,
            "fragmentPoint".ptr,
            "fragmentPoint".len,
            0, // rgba16float
            1, // enable blending
        );
        if (!self.point_pipeline.isValid()) {
            log("ERROR: Failed to create point pipeline");
            return error.PipelineCreationFailed;
        }

        log("✓ HDR pipelines created (glow, circle, point)");

        // === Compose Pipeline (HDR → Screen with tonemapping) ===
        log("Creating compose pipeline...");

        // Create compose shader
        self.compose_shader = shader.ShaderModule.create(shaders.compose_shader);
        if (!self.compose_shader.isValid()) {
            log("ERROR: Failed to create compose shader");
            return error.ShaderCreationFailed;
        }

        // Create compose bind group layout for textures
        const compose_layout_entries = [_]pipeline.BindGroupLayoutEntry{
            pipeline.BindGroupLayoutEntry.initTexture(0, pipeline.ShaderVisibility.FRAGMENT), // HDR texture
            pipeline.BindGroupLayoutEntry.initTexture(1, pipeline.ShaderVisibility.FRAGMENT), // Blue noise
        };
        self.compose_bind_group_layout = pipeline.BindGroupLayout.create(&compose_layout_entries);

        // Create compose bind group (HDR texture + blue noise)
        const compose_bind_entries = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initTextureView(0, self.hdr_texture_view.handle),
            // Blue noise will be bound later once we get the handle from JavaScript
            // For now, just bind the HDR texture view as placeholder
            pipeline.BindGroupEntry.initTextureView(1, self.hdr_texture_view.handle),
        };
        self.compose_bind_group = pipeline.BindGroup.create(self.compose_bind_group_layout, &compose_bind_entries);

        // Create compose pipeline (renders to screen, no blending needed)
        const compose_layout_array = [_]pipeline.BindGroupLayout{self.compose_bind_group_layout};
        const compose_pipeline_layout = pipeline.PipelineLayout.create(&compose_layout_array);

        // Compose pipeline uses screen format (bgra8unorm), no blending
        const compose_pipeline_id = js_webgpu_create_render_pipeline(
            device.getDevice().id,
            compose_pipeline_layout.handle.id,
            self.compose_shader.handle.id,
            "vertexMain".ptr,
            "vertexMain".len,
            "fragmentMain".ptr,
            "fragmentMain".len,
        );
        self.compose_pipeline = .{ .id = compose_pipeline_id };

        if (!self.compose_pipeline.isValid()) {
            log("ERROR: Failed to create compose pipeline");
            return error.PipelineCreationFailed;
        }

        log("✓ Compose pipeline created");

        // Legacy pipeline for fallback (screen format, no blending)
        const legacy_pipeline_id = js_webgpu_create_render_pipeline(
            device.getDevice().id,
            pipeline_layout.handle.id,
            self.render_shader.handle.id,
            "vertex_main".ptr,
            "vertex_main".len,
            "fragment_main".ptr,
            "fragment_main".len,
        );
        self.render_pipeline_handle = .{ .id = legacy_pipeline_id };

        log("✓ HDR render pipeline setup complete");
    }

    var camera_update_count: u32 = 0;

    pub fn handleInput(self: *Simulation, input: *const webinputs.InputState, _: f32) void {
        // Update simulation options
        self.friction_coefficient = input.friction;
        self.options.dt = input.time_step;
        self.options.looping_borders = if (input.looping_borders) 1.0 else 0.0;
        self.options.central_force = input.central_force;
        // self.options.force_strength = input.force_strength; // Need to implement this in options struct if needed

        // Camera Pan
        if (input.pan_x != 0 or input.pan_y != 0) {
            // Adjust pan speed based on zoom level (more zoom = slower pan)
            // pixels_per_unit is high when zoomed in, low when zoomed out
            // We want to move in world units
            const pan_speed = 1.0 / self.camera.pixels_per_unit;
            self.camera.center_x -= input.pan_x * pan_speed;
            self.camera.center_y += input.pan_y * pan_speed;

            // TODO: Implement Z panning if needed, e.g. using mouse wheel with modifier key

            self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});
        }

        // Camera Zoom
        if (input.zoom_delta != 0) {
            const zoom_speed = 0.001;
            const zoom_factor = 1.0 + input.zoom_delta * zoom_speed;

            // Zoom towards mouse position (2D only for now)
            // 1. Convert mouse to world space relative to camera center
            // Mouse is in pixels from top-left. Center is at canvas_width/2, canvas_height/2
            const mouse_x_ndc = (input.mouse_x / @as(f32, @floatFromInt(self.canvas_width))) * 2.0 - 1.0;
            const mouse_y_ndc = 1.0 - (input.mouse_y / @as(f32, @floatFromInt(self.canvas_height))) * 2.0; // Flip Y

            // Simple 2D approximation for zoom logic
            const mouse_world_x = self.camera.center_x + mouse_x_ndc * self.camera.extent_x;
            const mouse_world_y = self.camera.center_y + mouse_y_ndc * self.camera.extent_y;

            // 2. Apply zoom
            self.camera.extent_x *= zoom_factor;
            self.camera.extent_y *= zoom_factor;

            // 3. Adjust center to keep mouse at same world position (approximate)
            self.camera.center_x = mouse_world_x - mouse_x_ndc * self.camera.extent_x;
            self.camera.center_y = mouse_world_y - mouse_y_ndc * self.camera.extent_y;

            // Recalculate pixels per unit
            self.camera.pixels_per_unit = @as(f32, @floatFromInt(self.canvas_width)) / (2.0 * self.camera.extent_x);

            self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});
        }

        // Camera Rotation (Shift+RMB)
        if (input.rotate_x != 0 or input.rotate_y != 0) {
            const rotation_speed: f32 = 0.005;
            const pi: f32 = 3.14159265;

            // Yaw: horizontal mouse movement rotates around Y axis
            self.camera.yaw += input.rotate_x * rotation_speed;

            // Pitch: vertical mouse movement rotates around X axis
            // Clamp pitch to avoid flipping over
            self.camera.pitch += input.rotate_y * rotation_speed;
            self.camera.pitch = @max(-pi / 2.0 + 0.1, @min(pi / 2.0 - 0.1, self.camera.pitch));

            self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});
        }

        // Particle Interaction (LMB only - attracts particles)
        if (input.mouse_down) {
            const canvas_width_f: f32 = @as(f32, @floatFromInt(self.canvas_width));
            const canvas_height_f: f32 = @as(f32, @floatFromInt(self.canvas_height));

            // Convert mouse to world space (approximate - assumes interaction in center Z plane)
            const mouse_x_ndc = if (canvas_width_f > 0) (input.mouse_x / canvas_width_f) * 2.0 - 1.0 else 0.0;
            const mouse_y_ndc = if (canvas_height_f > 0) 1.0 - (input.mouse_y / canvas_height_f) * 2.0 else 0.0;

            // Map screen coordinates back to world space (inverse of rotation)
            // We need to account for camera rotation when computing interaction point
            const cos_yaw = @cos(self.camera.yaw);
            const sin_yaw = @sin(self.camera.yaw);
            const cos_pitch = @cos(self.camera.pitch);
            const sin_pitch = @sin(self.camera.pitch);

            // Screen space to view space
            const view_x = mouse_x_ndc * self.camera.extent_x;
            const view_y = mouse_y_ndc * self.camera.extent_y;

            // Inverse pitch rotation (from view Y to world Y and Z contribution)
            const y1 = view_y * cos_pitch;
            const z1 = view_y * sin_pitch;

            // Inverse yaw rotation (from view X to world X and Z)
            const world_x = view_x * cos_yaw - z1 * sin_yaw + self.camera.center_x;
            const world_z = view_x * sin_yaw + z1 * cos_yaw + self.camera.center_z;
            const world_y = y1 + self.camera.center_y;

            self.options.action_x = world_x;
            self.options.action_y = world_y;
            self.options.action_z = world_z;

            // Mouse drag -> world velocity
            const drag_x_ndc = if (canvas_width_f > 0) (input.mouse_dx * 2.0) / canvas_width_f else 0.0;
            const drag_y_ndc = if (canvas_height_f > 0) (-input.mouse_dy * 2.0) / canvas_height_f else 0.0;

            self.options.action_vx = self.camera.extent_x * drag_x_ndc;
            self.options.action_vy = self.camera.extent_y * drag_y_ndc;
            self.options.action_vz = 0.0;

            // Set action parameters - LMB attracts
            self.options.action_radius = self.camera.extent_x / 16.0;
            self.options.action_force = 20.0;
        } else {
            self.options.action_force = 0.0;
            self.options.action_vx = 0.0;
            self.options.action_vy = 0.0;
            self.options.action_vz = 0.0;
            self.options.action_radius = 0.0;
        }
    }

    pub fn updateCamera(self: *Simulation, canvas_width: f32, canvas_height: f32) void {
        const new_width = @as(u32, @intFromFloat(canvas_width));
        const new_height = @as(u32, @intFromFloat(canvas_height));

        // Recreate HDR texture if canvas size changed
        if (new_width != self.canvas_width or new_height != self.canvas_height) {
            self.canvas_width = new_width;
            self.canvas_height = new_height;

            // Destroy old HDR texture
            self.hdr_texture.destroy();

            // Create new HDR texture with updated size
            self.hdr_texture = texture.createHDRTexture(new_width, new_height);
            self.hdr_texture_view = self.hdr_texture.createView();

            // Recreate compose bind group with new HDR texture view
            // If we have blue noise, use it, otherwise fallback to HDR texture (no dithering)
            const blue_noise_view = if (self.blue_noise_texture_view) |bn| bn else self.hdr_texture_view.handle;

            const compose_bind_entries = [_]pipeline.BindGroupEntry{
                pipeline.BindGroupEntry.initTextureView(0, self.hdr_texture_view.handle),
                pipeline.BindGroupEntry.initTextureView(1, blue_noise_view),
            };
            self.compose_bind_group = pipeline.BindGroup.create(self.compose_bind_group_layout, &compose_bind_entries);

            log("HDR texture recreated for new canvas size");
        }

        self.camera = particle.CameraParams.initForSimulation(canvas_width, canvas_height, self.sim_width, self.sim_height, self.sim_depth);
        self.camera_buffer.writeTyped(particle.CameraParams, 0, &[_]particle.CameraParams{self.camera});

        camera_update_count += 1;
        if (camera_update_count <= 2) {
            log("=== Camera Updated ===");
            logInt("  Canvas width:", new_width);
            logInt("  Canvas height:", new_height);
            logInt("  Sim width:", @as(u32, @intFromFloat(self.sim_width)));
            logInt("  Sim height:", @as(u32, @intFromFloat(self.sim_height)));
            logInt("  Sim depth:", @as(u32, @intFromFloat(self.sim_depth)));

            // Log camera extent
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "  Camera extent: {d:.1} x {d:.1}", .{ self.camera.extent_x, self.camera.extent_y }) catch "Error";
            js_console_log(msg.ptr, msg.len);

            const msg2 = std.fmt.bufPrint(&buf, "  Pixels per unit: {d:.2}", .{self.camera.pixels_per_unit}) catch "Error";
            js_console_log(msg2.ptr, msg2.len);
        }
    }

    var frame_count: u32 = 0;

    pub fn update(self: *Simulation, dt: f32) void {
        // Update simulation parameters
        const clamped_dt = @min(dt, 0.025); // Cap dt to prevent instability
        self.options.dt = clamped_dt;
        const coeff = self.friction_coefficient;
        const friction_factor = if (coeff <= 0.0) 1.0 else std.math.exp(-clamped_dt * coeff);
        self.options.friction = friction_factor;
        self.options_buffer.writeTyped(particle.SimulationOptions, 0, &[_]particle.SimulationOptions{self.options});

        // Run optimized spatial algorithm (returns encoder handle)
        if (self.use_spatial_optimization) {
            const encoder_handle = self.spatial_pipeline.computeForces(
                self.particle_count,
                self.particle_buffer.handle.id,
                self.spatial_pipeline.particle_temp_buffer.handle.id,
            );

            // Add advancement pass to the same encoder
            const advance_pass = js_webgpu_encoder_begin_compute_pass(encoder_handle);
            js_webgpu_compute_pass_set_pipeline(advance_pass, self.physics_pipeline.advance_pipeline.handle.id);
            js_webgpu_compute_pass_set_bind_group(advance_pass, 0, self.physics_pipeline.particle_group.handle.id);
            js_webgpu_compute_pass_set_bind_group(advance_pass, 1, self.physics_pipeline.options_group.handle.id);
            const workgroup_count = (self.particle_count + 63) / 64;
            js_webgpu_compute_pass_dispatch(advance_pass, workgroup_count, 1, 1);
            js_webgpu_compute_pass_end(advance_pass);

            // Finish and submit
            const cmd_buffer = js_webgpu_command_encoder_finish(encoder_handle);
            js_webgpu_queue_submit(device.getDevice().id, cmd_buffer);
        } else {
            // Fallback to simple physics (no forces, just advancement)
            self.physics_pipeline.update(self.particle_count);
        }

        // Debug logging every 60 frames
        frame_count += 1;
        if (frame_count % 60 == 0) {
            log("Simulation running (60 frames)");
        }
    }

    var render_frame_count: u32 = 0;

    pub fn render(self: *Simulation) void {
        if (!self.glow_pipeline.isValid() or !self.circle_pipeline.isValid() or !self.point_pipeline.isValid()) {
            log("ERROR: HDR pipelines not initialized");
            return;
        }

        render_frame_count += 1;
        if (render_frame_count == 1) {
            log("=== First Render Frame ===");
            logInt("  Particle count:", self.particle_count);
            logInt("  Glow pipeline:", self.glow_pipeline.id);
            logInt("  Circle pipeline:", self.circle_pipeline.id);
            logInt("  Compose pipeline:", self.compose_pipeline.id);
        }

        const vertex_count = self.particle_count * 6;

        // === PASS 1: Render particles to HDR texture ===
        const hdr_pass = js_webgpu_begin_render_pass_hdr(
            self.hdr_texture_view.handle.id,
            0.001, // Near-black clear (not pure black for visual debugging)
            0.001,
            0.001,
            0.0,
        );

        // Set bind groups (shared by all particle pipelines)
        js_webgpu_render_pass_set_bind_group(hdr_pass, 0, self.particle_bind_group.handle.id);
        js_webgpu_render_pass_set_bind_group(hdr_pass, 1, self.camera_bind_group.handle.id);

        // Draw glow layer (always rendered first for bloom effect)
        js_webgpu_render_pass_set_pipeline(hdr_pass, self.glow_pipeline.id);
        js_webgpu_render_pass_draw(hdr_pass, vertex_count, 1, 0, 0);

        // Draw circle or point layer based on zoom level
        // (pixels_per_unit < 1.0 means zoomed out, use point renderer)
        if (self.camera.pixels_per_unit < 1.0) {
            js_webgpu_render_pass_set_pipeline(hdr_pass, self.point_pipeline.id);
        } else {
            js_webgpu_render_pass_set_pipeline(hdr_pass, self.circle_pipeline.id);
        }
        js_webgpu_render_pass_draw(hdr_pass, vertex_count, 1, 0, 0);

        js_webgpu_render_pass_end(hdr_pass);

        // === PASS 2: Screen Pass ===
        const compose_pass = js_webgpu_begin_render_pass_for_particles(0.1, 0.0, 0.1, 1.0);

        if (self.compose_pipeline.isValid()) {
            js_webgpu_render_pass_set_pipeline(compose_pass, self.compose_pipeline.id);
            js_webgpu_render_pass_set_bind_group(compose_pass, 0, self.compose_bind_group.handle.id);
            js_webgpu_render_pass_draw(compose_pass, 3, 1, 0, 0);
        }

        js_webgpu_render_pass_end(compose_pass);

        // === Present ===
        js_webgpu_present();
    }

    pub fn setBlueNoiseTexture(self: *Simulation, view_handle: u32) void {
        // Store the view handle
        self.blue_noise_texture_view = handles.TextureViewHandle{ .id = view_handle };

        // Recreate compose bind group with the new texture
        const compose_bind_entries = [_]pipeline.BindGroupEntry{
            pipeline.BindGroupEntry.initTextureView(0, self.hdr_texture_view.handle),
            pipeline.BindGroupEntry.initTextureView(1, self.blue_noise_texture_view.?),
        };
        self.compose_bind_group = pipeline.BindGroup.create(self.compose_bind_group_layout, &compose_bind_entries);

        log("✓ Blue noise texture set and bind group updated");
    }

    pub fn deinit(self: *Simulation) void {
        self.particle_buffer.destroy();
        self.species_buffer.destroy();
        self.force_buffer.destroy();
        self.options_buffer.destroy();
        self.camera_buffer.destroy();
        self.init_seed_buffer.destroy();
        self.spatial_pipeline.deinit();
    }
};

// FFI declarations for render pipeline
extern fn js_webgpu_create_render_pipeline(
    device: u32,
    layout: u32,
    shader: u32,
    vertex_entry_ptr: [*]const u8,
    vertex_entry_len: usize,
    fragment_entry_ptr: [*]const u8,
    fragment_entry_len: usize,
) u32;

extern fn js_webgpu_create_render_pipeline_hdr(
    device: u32,
    layout: u32,
    shader: u32,
    vertex_entry_ptr: [*]const u8,
    vertex_entry_len: usize,
    fragment_entry_ptr: [*]const u8,
    fragment_entry_len: usize,
    format: u32, // 0 = rgba16float, 2 = bgra8unorm
    enable_blending: u32, // 0 = no blending, 1 = additive blending
) u32;

extern fn js_webgpu_begin_render_pass_for_particles(r: f32, g: f32, b: f32, a: f32) u32;
extern fn js_webgpu_begin_render_pass_hdr(texture_view: u32, r: f32, g: f32, b: f32, a: f32) u32;
extern fn js_webgpu_render_pass_set_pipeline(pass: u32, pipeline: u32) void;
extern fn js_webgpu_render_pass_set_bind_group(pass: u32, index: u32, bind_group: u32) void;
extern fn js_webgpu_render_pass_draw(pass: u32, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
extern fn js_webgpu_render_pass_end(pass: u32) void;
extern fn js_webgpu_present() void;

// Additional FFI for chaining compute passes
extern fn js_webgpu_encoder_begin_compute_pass(encoder: u32) u32;
extern fn js_webgpu_compute_pass_set_pipeline(pass: u32, pipeline: u32) void;
extern fn js_webgpu_compute_pass_set_bind_group(pass: u32, index: u32, bind_group: u32) void;
extern fn js_webgpu_compute_pass_dispatch(pass: u32, x: u32, y: u32, z: u32) void;
extern fn js_webgpu_compute_pass_end(pass: u32) void;
extern fn js_webgpu_command_encoder_finish(encoder: u32) u32;
extern fn js_webgpu_queue_submit(device: u32, cmd_buffer: u32) void;

// Helper logging functions
fn log(comptime msg: []const u8) void {
    js_console_log(msg.ptr, msg.len);
}

fn logInt(comptime prefix: []const u8, value: u32) void {
    // Simple integer logging by converting to string
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{s} {d}", .{ prefix, value }) catch "Error formatting";
    js_console_log(str.ptr, str.len);
}

extern fn js_console_log(ptr: [*]const u8, len: usize) void;
