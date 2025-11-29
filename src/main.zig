const std = @import("std");
const build_options = @import("build_options");

// WebGPU modules
const handles = @import("webgpu/handles.zig");
const device = @import("webgpu/device.zig");
const render = @import("webgpu/render.zig");
const buffer = @import("webgpu/buffer.zig");
const shader = @import("webgpu/shader.zig");
const pipeline = @import("webgpu/pipeline.zig");
const compute = @import("webgpu/compute.zig");

// Web utils
const webinputs = @import("webutils/webinputs.zig");

// Particle Life modules
const simulation = @import("particle_life/simulation.zig");
const particle = @import("particle_life/particle.zig");

// Global simulation state
var time_elapsed: f32 = 0.0;
var sim: ?simulation.Simulation = null;
var sim_initialized: bool = false;
var initial_seed: u32 = 42;
var last_canvas_width: f32 = 0;
var last_canvas_height: f32 = 0;

// Simulation parameters
var particle_count: u32 = 65536; // Default matches slider
var species_count: u32 = 6; // Default matches slider
var sim_width: f32 = 1024.0; // Default matches slider
var sim_height: f32 = 1024.0; // Default matches slider
var sim_depth: f32 = 1024.0; // 3D depth

// WASM FFI exports - these will be called from JavaScript

/// Initialize the simulation
/// Called once after WASM loads and WebGPU is ready
export fn init(seed: u32) void {
    initial_seed = seed;
    log("Zig WebGPU Particle Life - Initialized!");

    const ts = @as(u64, @intCast(build_options.build_timestamp));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    logFmt("Build Time: {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });

    log("WebGPU device ready");
}

/// Set the WebGPU device handle (called from JS after device creation)
export fn setDevice(device_handle: u32) void {
    device.init(device_handle);

    if (device.isInitialized()) {
        log("Device handle received and initialized");
    } else {
        log("ERROR: Failed to initialize device");
    }
}

/// Set the blue noise texture for dithering
export fn setBlueNoiseTexture(texture_handle: u32, view_handle: u32) void {
    _ = texture_handle; // Not needed, we only need the view
    if (sim) |*s| {
        s.setBlueNoiseTexture(view_handle);
    }
}

/// Called when canvas resizes
export fn onResize(width: f32, height: f32) void {
    last_canvas_width = width;
    last_canvas_height = height;

    if (sim) |*s| {
        s.updateCamera(width, height);
    }
}

/// Update simulation frame
/// Called every frame from JavaScript's requestAnimationFrame
export fn update(dt: f32) void {
    time_elapsed += dt;

    // Only render if device is initialized
    if (!device.isInitialized()) {
        return;
    }

    // Initialize simulation on first frame
    if (!sim_initialized) {
        initSimulation();
        sim_initialized = true;
    }

    // Update and render particles!
    if (sim) |*s| {
        s.handleInput(&webinputs.state, dt);
        s.update(dt);
        s.render();

        // Reset per-frame input state
        webinputs.state.resetPerFrame();
    }
}

/// Initialize the particle simulation
fn initSimulation() void {
    log("=== Initializing Particle Life Simulation (3D) ===");

    // Clean up existing simulation if any
    if (sim) |*s| {
        s.deinit();
        sim = null;
    }

    sim = simulation.Simulation.init(
        particle_count,
        species_count,
        sim_width,
        sim_height,
        sim_depth,
        initial_seed,
        webinputs.state.symmetric_forces,
        webinputs.state.friction,
    ) catch {
        log("ERROR: Failed to initialize simulation");
        return;
    };

    if (last_canvas_width > 0 and last_canvas_height > 0) {
        if (sim) |*s| {
            s.updateCamera(last_canvas_width, last_canvas_height);
        }
    }

    log("✓ Particle simulation initialized");
}

// === New Exports for UI Controls ===

export fn setParticleCount(count: u32) void {
    if (particle_count != count) {
        particle_count = count;
        if (sim_initialized) {
            initSimulation();
        }
    }
}

export fn setSpeciesCount(count: u32) void {
    if (species_count != count) {
        species_count = count;
        if (sim_initialized) {
            initSimulation();
        }
    }
}

export fn setSimulationSize(width: f32, height: f32, depth: f32) void {
    if (sim_width != width or sim_height != height or sim_depth != depth) {
        sim_width = width;
        sim_height = height;
        sim_depth = depth;
        if (sim_initialized) {
            initSimulation();
        }
    }
}

export fn randomize() void {
    // Simple LCG to generate new seed from current one
    initial_seed = (initial_seed *% 1664525) +% 1013904223;
    if (sim_initialized) {
        initSimulation();
    }
}

export fn restart() void {
    if (sim_initialized) {
        initSimulation();
    }
}

export fn centerView() void {
    if (sim) |*s| {
        // Re-calling updateCamera with current dimensions resets the view
        s.updateCamera(@floatFromInt(s.canvas_width), @floatFromInt(s.canvas_height));
    }
}

/// Get version string for testing
export fn getVersion() [*:0]const u8 {
    return "0.0.1";
}

// Helper function to log messages to JavaScript console
fn log(comptime msg: []const u8) void {
    js_console_log(msg.ptr, msg.len);
}

// Helper function to log formatted messages
fn logFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch {
        log("Error formatting log message");
        return;
    };
    js_console_log(slice.ptr, slice.len);
}

// FFI import from JavaScript - console logging
extern fn js_console_log(ptr: [*]const u8, len: usize) void;
