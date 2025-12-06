// Particle Life - Particle Data Structures
//
// Based on Nikita Lisitsa's Particle Life simulation
// Reference: https://lisyarus.github.io/blog/posts/particle-life-simulation-in-browser-using-webgpu.html

const std = @import("std");

/// Single particle with position, velocity, and species
/// Matches WGSL struct layout (4-byte aligned floats)
pub const Particle = extern struct {
    x: f32,
    y: f32,
    z: f32,
    vx: f32,
    vy: f32,
    vz: f32,
    species: f32, // Species as float for GPU compatibility
    _padding: f32 = 0.0, // Pad to 32 bytes (8 floats)

    pub fn init(x: f32, y: f32, z: f32, species: u32) Particle {
        return .{
            .x = x,
            .y = y,
            .z = z,
            .vx = 0.0,
            .vy = 0.0,
            .vz = 0.0,
            .species = @floatFromInt(species),
        };
    }
};

/// Species visual properties
pub const Species = extern struct {
    color: [4]f32, // RGBA

    pub fn init(r: f32, g: f32, b: f32, a: f32) Species {
        return .{ .color = [4]f32{ r, g, b, a } };
    }

    pub fn fromRGB(r: f32, g: f32, b: f32) Species {
        return init(r, g, b, 1.0);
    }
};

/// Inter-species force parameters
pub const Force = extern struct {
    strength: f32, // Positive = attraction, negative = repulsion
    radius: f32, // Maximum force distance
    collision_strength: f32, // Collision repulsion strength
    collision_radius: f32, // Collision distance

    pub fn init(strength: f32, radius: f32) Force {
        return .{
            .strength = strength,
            .radius = radius,
            .collision_strength = 10.0,
            .collision_radius = 0.5,
        };
    }
};

/// Simulation parameters
pub const SimulationOptions = extern struct {
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    back: f32,
    front: f32,
    friction: f32,
    dt: f32,
    bin_size: f32,
    species_count: f32,
    central_force: f32,
    looping_borders: f32,
    action_x: f32,
    action_y: f32,
    action_z: f32,
    action_vx: f32,
    action_vy: f32,
    action_vz: f32,
    action_force: f32,
    action_radius: f32,
    _padding: [4]f32 = undefined, // Pad to ensure 16-byte alignment (96 bytes total)

    pub fn init(width: f32, height: f32, depth: f32, species_count: u32) SimulationOptions {
        return .{
            .left = -width / 2.0,
            .right = width / 2.0,
            .bottom = -height / 2.0,
            .top = height / 2.0,
            .back = -depth / 2.0,
            .front = depth / 2.0,
            .friction = 1.0, // Will be calculated as exp(-dt * friction)
            .dt = 0.016, // ~60fps
            .bin_size = 32.0,
            .species_count = @floatFromInt(species_count),
            .central_force = 0.0,
            .looping_borders = 0.0, // 0.0 = bounce, 1.0 = wrap around
            .action_x = 0.0,
            .action_y = 0.0,
            .action_z = 0.0,
            .action_vx = 0.0,
            .action_vy = 0.0,
            .action_vz = 0.0,
            .action_force = 0.0,
            .action_radius = 0.0,
        };
    }
};

/// Camera parameters for rendering
pub const CameraParams = extern struct {
    center_x: f32,
    center_y: f32,
    center_z: f32,
    extent_x: f32,
    extent_y: f32,
    pixels_per_unit: f32,
    // Rotation angles (in radians)
    yaw: f32, // Rotation around Y axis (horizontal rotation)
    pitch: f32, // Rotation around X axis (vertical rotation)

    pub fn init(canvas_width: f32, canvas_height: f32) CameraParams {
        const aspect_ratio = canvas_width / canvas_height;
        // Start zoomed out to see the whole simulation
        const extent_x = 512.0; // Half the sim width (1024/2)
        const extent_y = extent_x / aspect_ratio;

        // Default isometric-like viewing angles
        const pi: f32 = 3.14159265;
        const default_yaw = pi / 4.0; // 45 degrees - looking at corner
        const default_pitch = pi / 6.0; // 30 degrees - looking down

        return .{
            .center_x = 0.0,
            .center_y = 0.0,
            .center_z = 0.0,
            .extent_x = extent_x,
            .extent_y = extent_y,
            .pixels_per_unit = canvas_width / (2.0 * extent_x),
            .yaw = default_yaw,
            .pitch = default_pitch,
        };
    }

    pub fn initForSimulation(canvas_width: f32, canvas_height: f32, sim_width: f32, sim_height: f32, sim_depth: f32) CameraParams {
        // Simulation is centered at (0, 0, 0) with bounds [-w/2, w/2] etc.
        // Camera center should match simulation center
        const center_x: f32 = 0.0;
        const center_y: f32 = 0.0;
        const center_z: f32 = 0.0;

        // Isometric projection transforms (x, y, z) to:
        //   x_iso = (x - z) * cos(30) = (x - z) * 0.866
        //   y_iso = y + (x + z) * sin(30) = y + (x + z) * 0.5
        //
        // For a box centered at origin with half-extents (hw, hh, hd):
        //   x_iso ranges from -(hw + hd) * 0.866 to (hw + hd) * 0.866
        //   y_iso ranges from -(hh + (hw + hd) * 0.5) to (hh + (hw + hd) * 0.5)
        const hw = sim_width / 2.0;
        const hh = sim_height / 2.0;
        const hd = sim_depth / 2.0;

        const cos30: f32 = 0.866;
        const sin30: f32 = 0.5;

        // Calculate the projected bounding box extents
        const iso_extent_x = (hw + hd) * cos30;
        const iso_extent_y = hh + (hw + hd) * sin30;

        // Add some margin (10%) to ensure particles at edges are visible
        const margin: f32 = 1.1;
        var extent_x = iso_extent_x * margin;
        var extent_y = iso_extent_y * margin;

        // Adjust for canvas aspect ratio - ensure the smaller extent fits
        const aspect_ratio = canvas_width / canvas_height;
        const current_aspect = extent_x / extent_y;

        if (current_aspect < aspect_ratio) {
            // Canvas is wider than our content - extend x to match aspect
            extent_x = extent_y * aspect_ratio;
        } else {
            // Canvas is taller than our content - extend y to match aspect
            extent_y = extent_x / aspect_ratio;
        }

        const pixels_per_unit = canvas_width / (2.0 * extent_x);

        // Default isometric-like viewing angles
        const pi: f32 = 3.14159265;
        const default_yaw = pi / 4.0; // 45 degrees - looking at corner
        const default_pitch = pi / 6.0; // 30 degrees - looking down

        return .{
            .center_x = center_x,
            .center_y = center_y,
            .center_z = center_z,
            .extent_x = extent_x,
            .extent_y = extent_y,
            .pixels_per_unit = pixels_per_unit,
            .yaw = default_yaw,
            .pitch = default_pitch,
        };
    }
};
