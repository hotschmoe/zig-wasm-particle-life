//! Particle Life for the browser: freestanding wasm32 driving WebGPU through
//! `web/main.js`. Every function exported here is called from JavaScript; the
//! GPU surface it calls back into is declared in `gpu.zig`.

const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu.zig");
const input_state = @import("input.zig");
const simulation = @import("particle_life/simulation.zig");
const system = @import("particle_life/system.zig");
const physics = @import("particle_life/physics.zig");

const Simulation = simulation.Simulation;

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = consoleLog,
};

const log = std.log;

const max_particles = 1 << 20;
const min_world_size = 64;

const App = struct {
    input: input_state.Input = .{},
    settings: input_state.Settings = .{},
    params: simulation.Params = .{
        .particle_count = 65536,
        .species_count = 6,
        .width = 1024,
        .height = 1024,
    },
    seed: u32 = 0,
    canvas_width: u32 = 0,
    canvas_height: u32 = 0,
    blue_noise: ?gpu.TextureView = null,
    paused: bool = false,
    /// Set by anything that needs a new system; the rebuild happens at the next frame.
    rebuild: bool = true,
    sim: ?Simulation = null,

    fn destroySimulation(self: *App) void {
        if (self.sim) |*sim| sim.deinit();
        self.sim = null;
    }

    fn createSimulation(self: *App) void {
        self.rebuild = false;
        self.destroySimulation();
        self.sim = Simulation.init(.{
            .params = self.params,
            .canvas_width = self.canvas_width,
            .canvas_height = self.canvas_height,
            .seed = self.seed,
            .symmetric_forces = self.settings.symmetric_forces,
            .blue_noise = self.blue_noise,
        }) catch |err| {
            log.err("simulation setup failed: {t}", .{err});
            return;
        };
    }
};

var app: App = .{};

export fn init(seed: u32) void {
    app.seed = seed;
    log.info("build time: {s}", .{build_options.build_time});
}

/// Called once the blue-noise dither texture is uploaded.
export fn setBlueNoise(view: u32) void {
    const handle: gpu.TextureView = @fromBackingInt(@intCast(view));
    app.blue_noise = handle;
    const sim = &(app.sim orelse return);
    sim.setBlueNoise(handle) catch |err| {
        log.err("blue noise binding failed: {t}", .{err});
        app.destroySimulation();
    };
}

/// Canvas size in device pixels.
export fn onResize(width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    app.canvas_width = width;
    app.canvas_height = height;
    const sim = &(app.sim orelse return);
    sim.resize(width, height) catch |err| {
        log.err("resize failed: {t}", .{err});
        app.destroySimulation();
    };
}

/// Runs one frame; `dt` is seconds since the previous call.
export fn update(dt: f32) void {
    if (app.canvas_width == 0) return;
    if (app.rebuild) app.createSimulation();
    const sim = &(app.sim orelse return);
    sim.frame(&app.input, app.settings, if (app.paused) 0 else dt);
    app.input.endFrame();
}

export fn setPaused(paused: bool) void {
    app.paused = paused;
}

export fn setParticleCount(count: u32) void {
    const clamped = std.math.clamp(count, 1, max_particles);
    if (clamped == app.params.particle_count) return;
    app.params.particle_count = clamped;
    app.rebuild = true;
}

export fn setSpeciesCount(count: u32) void {
    const clamped = std.math.clamp(count, 1, system.max_species);
    if (clamped == app.params.species_count) return;
    app.params.species_count = clamped;
    app.rebuild = true;
}

export fn setSimulationSize(width: u32, height: u32) void {
    const w: f32 = @floatFromInt(std.math.clamp(width, min_world_size, physics.max_world_size));
    const h: f32 = @floatFromInt(std.math.clamp(height, min_world_size, physics.max_world_size));
    if (w == app.params.width and h == app.params.height) return;
    app.params.width = w;
    app.params.height = h;
    app.rebuild = true;
}

/// New random system, derived from the previous seed.
export fn randomize() void {
    app.seed = app.seed *% 1664525 +% 1013904223;
    app.rebuild = true;
}

/// Same seed, fresh particles.
export fn restart() void {
    app.rebuild = true;
}

export fn centerView() void {
    if (app.sim) |*sim| sim.centerView();
}

export fn setMousePosition(x: f32, y: f32) void {
    app.input.moveMouse(x, y);
}

export fn setMouseDown(down: bool) void {
    app.input.mouse_down = down;
}

export fn setMouseRightDown(down: bool) void {
    app.input.mouse_right_down = down;
}

export fn setZoom(delta: f32) void {
    app.input.zoom_delta = delta;
}

export fn setPan(dx: f32, dy: f32) void {
    app.input.pan_x = dx;
    app.input.pan_y = dy;
}

export fn setFriction(friction: f32) void {
    app.settings.friction = @max(friction, 0);
}

export fn setCentralForce(force: f32) void {
    app.settings.central_force = force;
}

export fn setLoopingBorders(enabled: bool) void {
    app.settings.looping_borders = enabled;
}

/// Takes effect the next time a system is generated.
export fn setSymmetricForces(enabled: bool) void {
    app.settings.symmetric_forces = enabled;
}

fn consoleLog(
    comptime level: log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    writer.print(comptime level.asText() ++ ": " ++ format, args) catch {};
    const message = writer.buffered();
    js.log(message.ptr, message.len);
}

const js = struct {
    extern "env" fn log(ptr: [*]const u8, len: usize) void;
};
