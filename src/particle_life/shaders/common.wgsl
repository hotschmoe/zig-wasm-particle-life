// Particle structure
struct Particle {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    species: f32,
}

// Simulation options
struct SimulationOptions {
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    friction: f32,
    dt: f32,
    bin_size: f32,
    species_count: f32,
    central_force: f32,
    looping_borders: f32,
    action_x: f32,
    action_y: f32,
    action_vx: f32,
    action_vy: f32,
    action_force: f32,
    action_radius: f32,
}

// Force between species
struct Force {
    strength: f32,
    radius: f32,
    collision_strength: f32,
    collision_radius: f32,
}

// Bin information
struct BinInfo {
    grid_size: vec2i,
    bin_id: vec2i,
    bin_index: i32,
}

// Calculate which bin a position belongs to
fn getBinInfo(position: vec2f, options: SimulationOptions) -> BinInfo {
    let grid_size = vec2i(
        i32(ceil((options.right - options.left) / options.bin_size)),
        i32(ceil((options.top - options.bottom) / options.bin_size)),
    );

    let bin_id = vec2i(
        clamp(i32(floor((position.x - options.left) / options.bin_size)), 0, grid_size.x - 1),
        clamp(i32(floor((position.y - options.bottom) / options.bin_size)), 0, grid_size.y - 1),
    );

    let bin_index = bin_id.y * grid_size.x + bin_id.x;

    return BinInfo(grid_size, bin_id, bin_index);
}
