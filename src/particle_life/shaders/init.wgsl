@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
@group(1) @binding(0) var<uniform> options: SimulationOptions;
@group(2) @binding(0) var<uniform> seed: u32;

fn pcg_hash(input: u32) -> u32 {
    let state = input * 747796405u + 2891336453u;
    let word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

fn random_float(id: u32, seed_val: u32) -> f32 {
    return f32(pcg_hash(id ^ pcg_hash(seed_val))) / 4294967296.0;
}

@compute @workgroup_size(64)
fn initParticles(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&particles)) {
        return;
    }

    var p = particles[id.x];

    // Random position
    let r1 = random_float(id.x * 5u + 0u, seed);
    let r2 = random_float(id.x * 5u + 1u, seed);

    let width = options.right - options.left;
    let height = options.top - options.bottom;

    p.x = options.left + r1 * width;
    p.y = options.bottom + r2 * height;

    // Random velocity
    let r3 = random_float(id.x * 5u + 2u, seed);
    let r4 = random_float(id.x * 5u + 3u, seed);
    let v_scale = 10.0;

    p.vx = (r3 * 2.0 - 1.0) * v_scale;
    p.vy = (r4 * 2.0 - 1.0) * v_scale;

    // Random species
    let r5 = random_float(id.x * 5u + 4u, seed);
    p.species = floor(r5 * options.species_count);
    if (p.species >= options.species_count) {
        p.species = options.species_count - 1.0;
    }

    particles[id.x] = p;
}
