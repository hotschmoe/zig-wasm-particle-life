// Particle Life - WGSL Shader Sources
//
// All shaders embedded as compile-time strings for easy deployment

/// Common WGSL utility functions and structures
const common_structs =
    \\// Particle structure
    \\struct Particle {
    \\    x: f32,
    \\    y: f32,
    \\    z: f32,
    \\    vx: f32,
    \\    vy: f32,
    \\    vz: f32,
    \\    species: f32,
    \\    _pad: f32, // Padding to match 32-byte alignment in Zig
    \\}
    \\
    \\// Simulation options
    \\struct SimulationOptions {
    \\    left: f32,
    \\    right: f32,
    \\    bottom: f32,
    \\    top: f32,
    \\    back: f32,
    \\    front: f32,
    \\    friction: f32,
    \\    dt: f32,
    \\    bin_size: f32,
    \\    species_count: f32,
    \\    central_force: f32,
    \\    looping_borders: f32,
    \\    action_x: f32,
    \\    action_y: f32,
    \\    action_z: f32,
    \\    action_vx: f32,
    \\    action_vy: f32,
    \\    action_vz: f32,
    \\    action_force: f32,
    \\    action_radius: f32,
    \\}
    \\
    \\// Force between species
    \\struct Force {
    \\    strength: f32,
    \\    radius: f32,
    \\    collision_strength: f32,
    \\    collision_radius: f32,
    \\}
    \\
    \\// Bin information
    \\struct BinInfo {
    \\    grid_size: vec3i,
    \\    bin_id: vec3i,
    \\    bin_index: i32,
    \\}
    \\
    \\// Calculate which bin a position belongs to
    \\fn getBinInfo(position: vec3f, options: SimulationOptions) -> BinInfo {
    \\    let grid_size = vec3i(
    \\        i32(ceil((options.right - options.left) / options.bin_size)),
    \\        i32(ceil((options.top - options.bottom) / options.bin_size)),
    \\        i32(ceil((options.front - options.back) / options.bin_size)),
    \\    );
    \\    
    \\    let bin_id = vec3i(
    \\        clamp(i32(floor((position.x - options.left) / options.bin_size)), 0, grid_size.x - 1),
    \\        clamp(i32(floor((position.y - options.bottom) / options.bin_size)), 0, grid_size.y - 1),
    \\        clamp(i32(floor((position.z - options.back) / options.bin_size)), 0, grid_size.z - 1),
    \\    );
    \\    
    \\    // 3D index: z * (width * height) + y * width + x
    \\    let bin_index = bin_id.z * (grid_size.x * grid_size.y) + bin_id.y * grid_size.x + bin_id.x;
    \\    
    \\    return BinInfo(grid_size, bin_id, bin_index);
    \\}
;

/// Spatial binning - Step 1: Clear and fill bin sizes
pub const spatial_binning = common_structs ++
    \\
    \\@group(0) @binding(0) var<storage, read> particles: array<Particle>;
    \\@group(1) @binding(0) var<uniform> options: SimulationOptions;
    \\@group(2) @binding(0) var<storage, read_write> bin_size: array<atomic<u32>>;
    \\
    \\@compute @workgroup_size(64)
    \\fn clearBinSize(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&bin_size)) {
    \\        return;
    \\    }
    \\    atomicStore(&bin_size[id.x], 0u);
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn fillBinSize(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&particles)) {
    \\        return;
    \\    }
    \\    
    \\    let particle = particles[id.x];
    \\    let bin_info = getBinInfo(vec3f(particle.x, particle.y, particle.z), options);
    \\    
    \\    atomicAdd(&bin_size[bin_info.bin_index + 1], 1u);
    \\}
;

/// Prefix sum for calculating bin offsets (Same as 2D)
pub const prefix_sum =
    \\@group(0) @binding(0) var<storage, read> source: array<u32>;
    \\@group(0) @binding(1) var<storage, read_write> destination: array<u32>;
    \\@group(0) @binding(2) var<uniform> step_size: u32;
    \\
    \\@compute @workgroup_size(64)
    \\fn prefixSumStep(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&source)) {
    \\        return;
    \\    }
    \\    
    \\    if (id.x < step_size) {
    \\        destination[id.x] = source[id.x];
    \\    } else {
    \\        destination[id.x] = source[id.x - step_size] + source[id.x];
    \\    }
    \\}
;

/// Particle sorting by spatial bins
pub const particle_sort = common_structs ++
    \\
    \\@group(0) @binding(0) var<storage, read> source: array<Particle>;
    \\@group(0) @binding(1) var<storage, read_write> destination: array<Particle>;
    \\@group(0) @binding(2) var<storage, read> bin_offset: array<u32>;
    \\@group(0) @binding(3) var<storage, read_write> bin_size: array<atomic<u32>>;
    \\@group(1) @binding(0) var<uniform> options: SimulationOptions;
    \\
    \\@compute @workgroup_size(64)
    \\fn clearBinSize(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&bin_size)) {
    \\        return;
    \\    }
    \\    atomicStore(&bin_size[id.x], 0u);
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn sortParticles(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&source)) {
    \\        return;
    \\    }
    \\    
    \\    let particle = source[id.x];
    \\    let bin_info = getBinInfo(vec3f(particle.x, particle.y, particle.z), options);
    \\    
    \\    let new_index = bin_offset[bin_info.bin_index] + atomicAdd(&bin_size[bin_info.bin_index], 1);
    \\    destination[new_index] = particle;
    \\}
;

/// Force computation between particles (3D)
pub const force_computation = common_structs ++
    \\
    \\@group(0) @binding(0) var<storage, read> particles_source: array<Particle>;
    \\@group(0) @binding(1) var<storage, read_write> particles_destination: array<Particle>;
    \\@group(0) @binding(2) var<storage, read> bin_offset: array<u32>;
    \\@group(0) @binding(3) var<storage, read> forces: array<Force>;
    \\@group(1) @binding(0) var<uniform> options: SimulationOptions;
    \\
    \\@compute @workgroup_size(64)
    \\fn computeForces(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&particles_source)) {
    \\        return;
    \\    }
    \\    
    \\    var particle = particles_source[id.x];
    \\    let species = u32(particle.species);
    \\    let bin_info = getBinInfo(vec3f(particle.x, particle.y, particle.z), options);
    \\    let looping_borders = options.looping_borders == 1.0;
    \\    
    \\    var bin_x_min = bin_info.bin_id.x - 1;
    \\    var bin_y_min = bin_info.bin_id.y - 1;
    \\    var bin_z_min = bin_info.bin_id.z - 1;
    \\    var bin_x_max = bin_info.bin_id.x + 1;
    \\    var bin_y_max = bin_info.bin_id.y + 1;
    \\    var bin_z_max = bin_info.bin_id.z + 1;
    \\    
    \\    if (!looping_borders) {
    \\        bin_x_min = max(0, bin_x_min);
    \\        bin_y_min = max(0, bin_y_min);
    \\        bin_z_min = max(0, bin_z_min);
    \\        bin_x_max = min(bin_info.grid_size.x - 1, bin_x_max);
    \\        bin_y_max = min(bin_info.grid_size.y - 1, bin_y_max);
    \\        bin_z_max = min(bin_info.grid_size.z - 1, bin_z_max);
    \\    }
    \\    
    \\    let width = options.right - options.left;
    \\    let height = options.top - options.bottom;
    \\    let depth = options.front - options.back;
    \\    var total_force = vec3f(0.0, 0.0, 0.0);
    \\    let particle_pos = vec3f(particle.x, particle.y, particle.z);
    \\    
    \\    total_force -= particle_pos * options.central_force;
    \\    
    \\    for (var bin_x = bin_x_min; bin_x <= bin_x_max; bin_x += 1) {
    \\        for (var bin_y = bin_y_min; bin_y <= bin_y_max; bin_y += 1) {
    \\            for (var bin_z = bin_z_min; bin_z <= bin_z_max; bin_z += 1) {
    \\                let real_bin_x = (bin_x + bin_info.grid_size.x) % bin_info.grid_size.x;
    \\                let real_bin_y = (bin_y + bin_info.grid_size.y) % bin_info.grid_size.y;
    \\                let real_bin_z = (bin_z + bin_info.grid_size.z) % bin_info.grid_size.z;
    \\                let bin_index = real_bin_z * (bin_info.grid_size.x * bin_info.grid_size.y) + real_bin_y * bin_info.grid_size.x + real_bin_x;
    \\                
    \\                let bin_start = bin_offset[bin_index];
    \\                let bin_end = bin_offset[bin_index + 1];
    \\                
    \\                for (var j = bin_start; j < bin_end; j += 1) {
    \\                    if (j == id.x) {
    \\                        continue;
    \\                    }
    \\
    \\                    let other = particles_source[j];
    \\                    let other_species = u32(other.species);
    \\                    let force = forces[species * u32(options.species_count) + other_species];
    \\
    \\                    var r = vec3f(other.x, other.y, other.z) - particle_pos;
    \\
    \\                    if (looping_borders) {
    \\                        if (abs(r.x) >= width * 0.5) {
    \\                            r.x -= sign(r.x) * width;
    \\                        }
    \\                        if (abs(r.y) >= height * 0.5) {
    \\                            r.y -= sign(r.y) * height;
    \\                        }
    \\                        if (abs(r.z) >= depth * 0.5) {
    \\                            r.z -= sign(r.z) * depth;
    \\                        }
    \\                    }
    \\
    \\                    let d = length(r);
    \\                    if (d > 0.0 && d < force.radius) {
    \\                        let n = r / d;
    \\                        total_force += force.strength * max(0.0, 1.0 - d / force.radius) * n;
    \\                        total_force -= force.collision_strength * max(0.0, 1.0 - d / force.collision_radius) * n;
    \\                    }
    \\                }
    \\            }
    \\        }
    \\    }
    \\    
    \\    particle.vx += total_force.x * options.dt;
    \\    particle.vy += total_force.y * options.dt;
    \\    particle.vz += total_force.z * options.dt;
    \\    
    \\    particles_destination[id.x] = particle;
    \\}
;

/// Particle advancement - integrate velocity and handle boundaries (3D)
pub const particle_advance = common_structs ++
    \\
    \\@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
    \\@group(1) @binding(0) var<uniform> options: SimulationOptions;
    \\
    \\@compute @workgroup_size(64)
    \\fn particleAdvance(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&particles)) {
    \\        return;
    \\    }
    \\    
    \\    let width = options.right - options.left;
    \\    let height = options.top - options.bottom;
    \\    let depth = options.front - options.back;
    \\    var particle = particles[id.x];
    \\    
    \\    // Apply action force (user interaction) - mostly 2D interaction projected or 3D if UI supports
    \\    var action_r = vec3f(particle.x, particle.y, particle.z) - vec3f(options.action_x, options.action_y, options.action_z);
    \\    if (options.looping_borders == 1.0) {
    \\        if (abs(action_r.x) >= width * 0.5) {
    \\            action_r.x -= sign(action_r.x) * width;
    \\        }
    \\        if (abs(action_r.y) >= height * 0.5) {
    \\            action_r.y -= sign(action_r.y) * height;
    \\        }
    \\        if (abs(action_r.z) >= depth * 0.5) {
    \\            action_r.z -= sign(action_r.z) * depth;
    \\        }
    \\    }
    \\    let action_factor = options.action_force * exp(-dot(action_r, action_r) / (options.action_radius * options.action_radius));
    \\    particle.vx += options.action_vx * action_factor;
    \\    particle.vy += options.action_vy * action_factor;
    \\    particle.vz += options.action_vz * action_factor;
    \\    
    \\    // Apply friction
    \\    particle.vx *= options.friction;
    \\    particle.vy *= options.friction;
    \\    particle.vz *= options.friction;
    \\    
    \\    // Integrate velocity -> position
    \\    particle.x += particle.vx * options.dt;
    \\    particle.y += particle.vy * options.dt;
    \\    particle.z += particle.vz * options.dt;
    \\    
    \\    // Handle boundaries
    \\    let looping_borders = options.looping_borders == 1.0;
    \\    
    \\    if (looping_borders) {
    \\        if (particle.x < options.left) {
    \\            particle.x += width;
    \\        }
    \\        if (particle.x > options.right) {
    \\            particle.x -= width;
    \\        }
    \\        if (particle.y < options.bottom) {
    \\            particle.y += height;
    \\        }
    \\        if (particle.y > options.top) {
    \\            particle.y -= height;
    \\        }
    \\        if (particle.z < options.back) {
    \\            particle.z += depth;
    \\        }
    \\        if (particle.z > options.front) {
    \\            particle.z -= depth;
    \\        }
    \\    } else {
    \\        if (particle.x < options.left) {
    \\            particle.x = options.left;
    \\            particle.vx *= -1.0;
    \\        }
    \\        if (particle.x > options.right) {
    \\            particle.x = options.right;
    \\            particle.vx *= -1.0;
    \\        }
    \\        if (particle.y < options.bottom) {
    \\            particle.y = options.bottom;
    \\            particle.vy *= -1.0;
    \\        }
    \\        if (particle.y > options.top) {
    \\            particle.y = options.top;
    \\            particle.vy *= -1.0;
    \\        }
    \\        if (particle.z < options.back) {
    \\            particle.z = options.back;
    \\            particle.vz *= -1.0;
    \\        }
    \\        if (particle.z > options.front) {
    \\            particle.z = options.front;
    \\            particle.vz *= -1.0;
    \\        }
    \\    }
    \\    
    \\    particles[id.x] = particle;
    \\}
;

/// Particle Initialization on GPU (3D)
pub const particle_init = common_structs ++
    \\
    \\@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
    \\@group(1) @binding(0) var<uniform> options: SimulationOptions;
    \\@group(2) @binding(0) var<uniform> seed: u32;
    \\
    \\fn pcg_hash(input: u32) -> u32 {
    \\    let state = input * 747796405u + 2891336453u;
    \\    let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    \\    return (word >> 22u) ^ word;
    \\}
    \\
    \\fn random_float(id: u32, seed_val: u32) -> f32 {
    \\    return f32(pcg_hash(id ^ pcg_hash(seed_val))) / 4294967296.0;
    \\}
    \\
    \\@compute @workgroup_size(64)
    \\fn initParticles(@builtin(global_invocation_id) id: vec3u) {
    \\    if (id.x >= arrayLength(&particles)) {
    \\        return;
    \\    }
    \\    
    \\    var p = particles[id.x];
    \\    
    \\    // Random position
    \\    let r1 = random_float(id.x * 7u + 0u, seed);
    \\    let r2 = random_float(id.x * 7u + 1u, seed);
    \\    let r3 = random_float(id.x * 7u + 2u, seed);
    \\    
    \\    let width = options.right - options.left;
    \\    let height = options.top - options.bottom;
    \\    let depth = options.front - options.back;
    \\    
    \\    p.x = options.left + r1 * width;
    \\    p.y = options.bottom + r2 * height;
    \\    p.z = options.back + r3 * depth;
    \\    
    \\    // Random velocity
    \\    let r4 = random_float(id.x * 7u + 3u, seed);
    \\    let r5 = random_float(id.x * 7u + 4u, seed);
    \\    let r6 = random_float(id.x * 7u + 5u, seed);
    \\    let v_scale = 10.0; 
    \\    
    \\    p.vx = (r4 * 2.0 - 1.0) * v_scale;
    \\    p.vy = (r5 * 2.0 - 1.0) * v_scale;
    \\    p.vz = (r6 * 2.0 - 1.0) * v_scale;
    \\    
    \\    // Random species
    \\    let r7 = random_float(id.x * 7u + 6u, seed);
    \\    p.species = floor(r7 * options.species_count);
    \\    if (p.species >= options.species_count) {
    \\        p.species = options.species_count - 1.0;
    \\    }
    \\    
    \\    particles[id.x] = p;
    \\}
;

/// Simple particle point rendering shader
/// Renders each particle as a colored point based on its species (Isometric projection)
pub const particle_render_point =
    \\// Particle structure (must match Zig layout)
    \\struct Particle {
    \\    x: f32,
    \\    y: f32,
    \\    z: f32,
    \\    vx: f32,
    \\    vy: f32,
    \\    vz: f32,
    \\    species: f32,
    \\    _pad: f32,
    \\}
    \\
    \\// Species color
    \\struct Species {
    \\    color: vec4f,
    \\}
    \\
    \\// Camera parameters
    \\struct Camera {
    \\    center_x: f32,
    \\    center_y: f32,
    \\    center_z: f32,
    \\    extent_x: f32,
    \\    extent_y: f32,
    \\    pixels_per_unit: f32,
    \\}
    \\
    \\// Bindings
    \\@group(0) @binding(0) var<storage, read> particles: array<Particle>;
    \\@group(0) @binding(1) var<storage, read> species: array<Species>;
    \\@group(1) @binding(0) var<uniform> camera: Camera;
    \\
    \\// Vertex shader output
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4f,
    \\    @location(0) color: vec4f,
    \\}
    \\
    \\// Vertex shader - emit 6 vertices per particle (2 triangles = quad)
    \\@vertex
    \\fn vertex_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
    \\    let particle_index = vertex_index / 6u;
    \\    let vertex_in_quad = vertex_index % 6u;
    \\    
    \\    let particle = particles[particle_index];
    \\    let species_index = u32(particle.species);
    \\    let particle_color = species[species_index].color;
    \\    
    \\    // Particle size in world units (match reference: 1.5)
    \\    let size = 1.5;
    \\    
    \\    // Quad vertices (local coordinates)
    \\    var local_pos: vec2f;
    \\    if (vertex_in_quad == 0u || vertex_in_quad == 3u) {
    \\        local_pos = vec2f(-size, -size);
    \\    } else if (vertex_in_quad == 1u) {
    \\        local_pos = vec2f(size, -size);
    \\    } else if (vertex_in_quad == 2u || vertex_in_quad == 4u) {
    \\        local_pos = vec2f(size, size);
    \\    } else {
    \\        local_pos = vec2f(-size, size);
    \\    }
    \\
    \\    // Isometric projection
    \\    // x_iso = (x - z) * cos(30)
    \\    // y_iso = y + (x + z) * sin(30)
    \\    // Simplified:
    \\    let cos30 = 0.866;
    \\    let sin30 = 0.5;
    \\
    \\    let px = particle.x - camera.center_x;
    \\    let py = particle.y - camera.center_y;
    \\    let pz = particle.z - camera.center_z;
    \\
    \\    let x_iso = (px - pz) * cos30;
    \\    let y_iso = py + (px + pz) * sin30;
    \\    
    \\    // World position (projected)
    \\    let world_x = x_iso + local_pos.x;
    \\    let world_y = y_iso + local_pos.y;
    \\    
    \\    // Camera transform to NDC
    \\    let ndc_x = world_x / camera.extent_x;
    \\    let ndc_y = world_y / camera.extent_y;
    \\    
    \\    var output: VertexOutput;
    \\    output.position = vec4f(ndc_x, ndc_y, 0.0, 1.0);
    \\    output.color = particle_color;
    \\    return output;
    \\}
    \\
    \\// Fragment shader - simple solid color
    \\@fragment
    \\fn fragment_main(input: VertexOutput) -> @location(0) vec4f {
    \\    return input.color;
    \\}
;

/// Common shader structures for HDR rendering (3D)
const common_render_structs =
    \\// Particle structure
    \\struct Particle {
    \\    x: f32,
    \\    y: f32,
    \\    z: f32,
    \\    vx: f32,
    \\    vy: f32,
    \\    vz: f32,
    \\    species: f32,
    \\    _pad: f32,
    \\}
    \\
    \\// Species color
    \\struct Species {
    \\    color: vec4f,
    \\}
    \\
    \\// Camera parameters
    \\struct Camera {
    \\    center: vec3f,
    \\    extent: vec2f,
    \\    pixels_per_unit: f32,
    \\}
    \\
    \\// Bindings
    \\@group(0) @binding(0) var<storage, read> particles: array<Particle>;
    \\@group(0) @binding(1) var<storage, read> species: array<Species>;
    \\@group(1) @binding(0) var<uniform> camera: Camera;
    \\
    \\// Vertex output for circle rendering
    \\struct CircleVertexOut {
    \\    @builtin(position) position: vec4f,
    \\    @location(0) offset: vec2f,
    \\    @location(1) color: vec4f,
    \\}
    \\
    \\// Quad offsets (2 triangles = 6 vertices)
    \\const offsets = array<vec2f, 6>(
    \\    vec2f(-1.0, -1.0),
    \\    vec2f( 1.0, -1.0),
    \\    vec2f(-1.0,  1.0),
    \\    vec2f(-1.0,  1.0),
    \\    vec2f( 1.0, -1.0),
    \\    vec2f( 1.0,  1.0),
    \\);
    \\
    \\fn isometricProject(p: vec3f, camera_center: vec3f) -> vec2f {
    \\    let cos30 = 0.866;
    \\    let sin30 = 0.5;
    \\    let d = p - camera_center;
    \\    let x = (d.x - d.z) * cos30;
    \\    let y = d.y + (d.x + d.z) * sin30;
    \\    return vec2f(x, y);
    \\}
;

/// Glow effect renderer - soft, large halos (Isometric)
pub const particle_render_glow = common_render_structs ++
    \\
    \\@vertex
    \\fn vertexGlow(@builtin(vertex_index) id: u32) -> CircleVertexOut {
    \\    let particle = particles[id / 6u];
    \\    let offset = offsets[id % 6u];
    \\    let projected_pos = isometricProject(vec3f(particle.x, particle.y, particle.z), camera.center);
    \\    let position = projected_pos + 12.0 * offset;
    \\    return CircleVertexOut(
    \\        vec4f(position / camera.extent, 0.0, 1.0),
    \\        offset,
    \\        species[u32(particle.species)].color
    \\    );
    \\}
    \\
    \\@fragment
    \\fn fragmentGlow(in: CircleVertexOut) -> @location(0) vec4f {
    \\    let l = length(in.offset);
    \\    let alpha = exp(-6.0 * l * l) / 64.0;
    \\    return in.color * vec4f(1.0, 1.0, 1.0, alpha);
    \\}
;

/// Circle renderer - solid particles with anti-aliased edges (Isometric)
pub const particle_render_circle = common_render_structs ++
    \\
    \\@vertex
    \\fn vertexCircle(@builtin(vertex_index) id: u32) -> CircleVertexOut {
    \\    let particle = particles[id / 6u];
    \\    let offset = offsets[id % 6u] * 1.5;
    \\    let projected_pos = isometricProject(vec3f(particle.x, particle.y, particle.z), camera.center);
    \\    let position = projected_pos + offset;
    \\    return CircleVertexOut(
    \\        vec4f(position / camera.extent, 0.0, 1.0),
    \\        offset,
    \\        species[u32(particle.species)].color
    \\    );
    \\}
    \\
    \\@fragment
    \\fn fragmentCircle(in: CircleVertexOut) -> @location(0) vec4f {
    \\    let alpha = clamp(camera.pixels_per_unit - length(in.offset) * camera.pixels_per_unit + 0.5, 0.0, 1.0);
    \\    return in.color * vec4f(1.0, 1.0, 1.0, alpha);
    \\}
;

/// Point renderer - tiny square particles (Isometric)
pub const particle_render_point_hdr = common_render_structs ++
    \\
    \\@vertex
    \\fn vertexPoint(@builtin(vertex_index) id: u32) -> CircleVertexOut {
    \\    let particle = particles[id / 6u];
    \\    let offset = 2.0 * offsets[id % 6u] / camera.pixels_per_unit;
    \\    let projected_pos = isometricProject(vec3f(particle.x, particle.y, particle.z), camera.center);
    \\    let position = projected_pos + offset;
    \\    return CircleVertexOut(
    \\        vec4f(position / camera.extent, 0.0, 1.0),
    \\        offset,
    \\        species[u32(particle.species)].color
    \\    );
    \\}
    \\
    \\const PI = 3.1415926535;
    \\
    \\@fragment
    \\fn fragmentPoint(in: CircleVertexOut) -> @location(0) vec4f {
    \\    let d = max(vec2(0.0), min(in.offset * camera.pixels_per_unit + 0.5, vec2(camera.pixels_per_unit)) - max(in.offset * camera.pixels_per_unit - 0.5, -vec2(camera.pixels_per_unit)));
    \\    let alpha = (PI / 4.0) * d.x * d.y;
    \\    return vec4f(in.color.rgb, in.color.a * alpha);
    \\}
;

/// Compositing shader - HDR to screen with tonemapping
/// (Unchanged, operates on 2D texture)
pub const compose_shader =
    \\@group(0) @binding(0) var hdr_texture: texture_2d<f32>;
    \\@group(0) @binding(1) var blue_noise_texture: texture_2d<f32>;
    \\
    \\const vertices = array<vec2f, 3>(
    \\    vec2f(-1.0, -1.0),
    \\    vec2f( 3.0, -1.0),
    \\    vec2f(-1.0,  3.0),
    \\);
    \\
    \\struct VertexOut {
    \\    @builtin(position) position: vec4f,
    \\    @location(0) texcoord: vec2f,
    \\}
    \\
    \\@vertex
    \\fn vertexMain(@builtin(vertex_index) id: u32) -> VertexOut {
    \\    let vertex = vertices[id];
    \\    return VertexOut(
    \\        vec4f(vertex, 0.0, 1.0),
    \\        vertex * 0.5 + vec2f(0.5)
    \\    );
    \\}
    \\
    \\fn acesTonemap(x: vec3f) -> vec3f {
    \\    let a = 2.51;
    \\    let b = 0.03;
    \\    let c = 2.43;
    \\    let d = 0.59;
    \\    let e = 0.14;
    \\    return clamp((x*(a*x+b))/(x*(c*x+d)+e), vec3f(0.0), vec3f(1.0));
    \\}
    \\
    \\fn dither(x: vec3f, n: f32) -> vec3f {
    \\    let c = x * 255.0;
    \\    let c0 = floor(c);
    \\    let c1 = c0 + vec3f(1.0);
    \\    let dc = c - c0;
    \\    
    \\    var r = c0;
    \\    if (dc.r > n) { r.r = c1.r; }
    \\    if (dc.g > n) { r.g = c1.g; }
    \\    if (dc.b > n) { r.b = c1.b; }
    \\    
    \\    return r / 255.0;
    \\}
    \\
    \\@fragment
    \\fn fragmentMain(in: VertexOut) -> @location(0) vec4f {
    \\    var sample = textureLoad(hdr_texture, vec2i(in.position.xy), 0);
    \\    let noise = textureLoad(blue_noise_texture, vec2u(in.position.xy) % textureDimensions(blue_noise_texture), 0).r;
    \\    
    \\    var color = sample.rgb;
    \\    color = acesTonemap(color);
    \\    color = pow(color, vec3f(1.0 / 2.2));
    \\    color = dither(color, noise);
    \\    
    \\    return vec4f(color, 1.0);
    \\}
;
