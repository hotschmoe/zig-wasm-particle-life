//! One particle system: GPU resources, camera and per-frame control.

const std = @import("std");
const gpu = @import("../gpu.zig");
const input_state = @import("../input.zig");
const camera_math = @import("camera.zig");
const physics = @import("physics.zig");
const renderer = @import("renderer.zig");
const system = @import("system.zig");
const types = @import("types.zig");

const Camera = camera_math.Camera;

pub const Params = physics.Params;

/// Longest simulated step; longer frames are treated as this long.
const max_dt = 0.025;
/// Wheel delta to zoom factor.
const zoom_speed = 0.001;
/// Strength of the mouse attract/repel force.
const action_force = 20.0;

pub const Simulation = struct {
    pool: gpu.Pool,
    params: Params,
    physics: physics.Physics,
    renderer: renderer.Renderer,
    options: types.Options,
    camera: Camera,
    canvas_width: u32,
    canvas_height: u32,

    pub const InitOptions = struct {
        params: Params,
        canvas_width: u32,
        canvas_height: u32,
        seed: u32,
        symmetric_forces: bool,
        blue_noise: ?gpu.TextureView,
    };

    pub fn init(opts: InitOptions) gpu.Error!Simulation {
        const params = opts.params;
        var pool: gpu.Pool = .{};
        errdefer pool.deinit();

        const phys = try physics.Physics.init(&pool, params);
        var render = try renderer.Renderer.init(
            &pool,
            phys.particles,
            phys.species,
            params.particle_count,
            opts.canvas_width,
            opts.canvas_height,
            opts.blue_noise,
        );
        errdefer render.deinit();

        const sim: Simulation = .{
            .pool = pool,
            .params = params,
            .physics = phys,
            .renderer = render,
            .options = .{
                .left = -params.width / 2.0,
                .right = params.width / 2.0,
                .bottom = -params.height / 2.0,
                .top = params.height / 2.0,
                .bin_size = physics.bin_size,
                .species_count = @floatFromInt(params.species_count),
            },
            .camera = .fit(
                @floatFromInt(opts.canvas_width),
                @floatFromInt(opts.canvas_height),
                params.width,
                params.height,
            ),
            .canvas_width = opts.canvas_width,
            .canvas_height = opts.canvas_height,
        };
        sim.generate(opts.seed, opts.symmetric_forces);
        return sim;
    }

    pub fn deinit(sim: *Simulation) void {
        sim.renderer.deinit();
        sim.pool.deinit();
    }

    /// Scatters particles on the GPU and uploads a fresh random species/force table.
    fn generate(sim: Simulation, seed: u32, symmetric: bool) void {
        var rng: system.Rng = .init(seed);
        const species_count = sim.params.species_count;

        sim.physics.uploadOptions(sim.options);
        sim.physics.scatter(rng.nextU32());

        var species: [system.max_species]types.Species = undefined;
        var forces: [system.max_species * system.max_species]types.Force = undefined;
        const species_slice = species[0..species_count];
        const force_slice = forces[0 .. species_count * species_count];
        system.generateSpecies(species_slice, &rng);
        system.generateForces(force_slice, species_count, &rng, symmetric);
        gpu.writeBuffer(sim.physics.species, std.mem.sliceAsBytes(species_slice));
        gpu.writeBuffer(sim.physics.forces, std.mem.sliceAsBytes(force_slice));
        sim.renderer.uploadCamera(sim.camera);

        std.log.info("system generated: {d} particles, {d} species", .{ sim.params.particle_count, species_count });
    }

    pub fn resize(sim: *Simulation, width: u32, height: u32) gpu.Error!void {
        if (width != sim.canvas_width or height != sim.canvas_height) {
            try sim.renderer.resize(width, height);
            sim.canvas_width = width;
            sim.canvas_height = height;
        }
        sim.centerView();
    }

    /// Resets pan and zoom to frame the whole world.
    pub fn centerView(sim: *Simulation) void {
        sim.camera = .fit(
            @floatFromInt(sim.canvas_width),
            @floatFromInt(sim.canvas_height),
            sim.params.width,
            sim.params.height,
        );
        sim.renderer.uploadCamera(sim.camera);
    }

    pub fn setBlueNoise(sim: *Simulation, view: gpu.TextureView) gpu.Error!void {
        try sim.renderer.setBlueNoise(view);
    }

    pub fn frame(sim: *Simulation, input: *const input_state.Input, settings: input_state.Settings, dt: f32) void {
        sim.applyInput(input, settings);
        sim.step(settings.friction, dt);
        sim.renderer.draw(sim.camera.pixels_per_unit);
    }

    fn applyInput(sim: *Simulation, input: *const input_state.Input, settings: input_state.Settings) void {
        const canvas_width: f32 = @floatFromInt(sim.canvas_width);
        const canvas_height: f32 = @floatFromInt(sim.canvas_height);
        const options = &sim.options;
        const camera = &sim.camera;

        options.looping_borders = if (settings.looping_borders) 1.0 else 0.0;
        options.central_force = settings.central_force;

        var camera_dirty = false;
        if (input.pan_x != 0 or input.pan_y != 0) {
            camera.pan(input.pan_x, input.pan_y);
            camera_dirty = true;
        }
        if (input.zoom_delta != 0) {
            const ndc = camera_math.pixelToNdc(input.mouse_x, input.mouse_y, canvas_width, canvas_height);
            camera.zoom(1.0 + input.zoom_delta * zoom_speed, ndc, canvas_width);
            camera_dirty = true;
        }
        if (camera_dirty) sim.renderer.uploadCamera(camera.*);

        if (input.mouse_down or input.mouse_right_down) {
            const ndc = camera_math.pixelToNdc(input.mouse_x, input.mouse_y, canvas_width, canvas_height);
            const world = camera.toWorld(ndc);
            options.action_x = world[0];
            options.action_y = world[1];
            options.action_vx = camera.extent_x * (input.mouse_dx * 2.0 / canvas_width);
            options.action_vy = camera.extent_y * (-input.mouse_dy * 2.0 / canvas_height);
            options.action_radius = camera.extent_x / 16.0;
            options.action_force = if (input.mouse_down) action_force else -action_force;
        } else {
            options.action_force = 0.0;
            options.action_vx = 0.0;
            options.action_vy = 0.0;
            options.action_radius = 0.0;
        }
    }

    fn step(sim: *Simulation, friction: f32, dt: f32) void {
        const clamped = @min(dt, max_dt);
        sim.options.dt = clamped;
        sim.options.friction = std.math.exp(-clamped * friction);
        sim.physics.uploadOptions(sim.options);
        sim.physics.step();
    }
};
