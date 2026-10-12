//! Structs shared byte-for-byte with the WGSL shaders in `shaders/`.

/// Read back only for its size: particles are created and advanced on the GPU.
pub const Particle = extern struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    /// Species index stored as a float to match the shader struct.
    species: f32,
};

pub const Species = extern struct {
    color: [4]f32,
};

pub const Force = extern struct {
    /// Positive attracts, negative repels.
    strength: f32,
    radius: f32,
    collision_strength: f32,
    collision_radius: f32,
};

/// Uniform block `SimulationOptions`. Flags are floats because WGSL uniforms
/// are compared against `1.0` in the shaders.
pub const Options = extern struct {
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    friction: f32 = 1.0,
    dt: f32 = 0.016,
    bin_size: f32,
    species_count: f32,
    central_force: f32 = 0.0,
    looping_borders: f32 = 0.0,
    action_x: f32 = 0.0,
    action_y: f32 = 0.0,
    action_vx: f32 = 0.0,
    action_vy: f32 = 0.0,
    action_force: f32 = 0.0,
    action_radius: f32 = 0.0,
};
