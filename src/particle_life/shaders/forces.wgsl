@group(0) @binding(0) var<storage, read> particles_source: array<Particle>;
@group(0) @binding(1) var<storage, read_write> particles_destination: array<Particle>;
@group(0) @binding(2) var<storage, read> bin_offset: array<u32>;
@group(0) @binding(3) var<storage, read> forces: array<Force>;
@group(1) @binding(0) var<uniform> options: SimulationOptions;

@compute @workgroup_size(64)
fn computeForces(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&particles_source)) {
        return;
    }

    var particle = particles_source[id.x];
    let species = u32(particle.species);
    let bin_info = getBinInfo(vec2f(particle.x, particle.y), options);
    let looping_borders = options.looping_borders == 1.0;

    var bin_x_min = bin_info.bin_id.x - 1;
    var bin_y_min = bin_info.bin_id.y - 1;
    var bin_x_max = bin_info.bin_id.x + 1;
    var bin_y_max = bin_info.bin_id.y + 1;

    if (!looping_borders) {
        bin_x_min = max(0, bin_x_min);
        bin_y_min = max(0, bin_y_min);
        bin_x_max = min(bin_info.grid_size.x - 1, bin_x_max);
        bin_y_max = min(bin_info.grid_size.y - 1, bin_y_max);
    }

    let width = options.right - options.left;
    let height = options.top - options.bottom;
    var total_force = vec2f(0.0, 0.0);
    let particle_pos = vec2f(particle.x, particle.y);

    total_force -= particle_pos * options.central_force;

    for (var bin_x = bin_x_min; bin_x <= bin_x_max; bin_x += 1) {
        for (var bin_y = bin_y_min; bin_y <= bin_y_max; bin_y += 1) {
            let real_bin_x = (bin_x + bin_info.grid_size.x) % bin_info.grid_size.x;
            let real_bin_y = (bin_y + bin_info.grid_size.y) % bin_info.grid_size.y;
            let bin_index = real_bin_y * bin_info.grid_size.x + real_bin_x;

            let bin_start = bin_offset[bin_index];
            let bin_end = bin_offset[bin_index + 1];

            for (var j = bin_start; j < bin_end; j += 1) {
                if (j == id.x) {
                    continue;
                }

                let other = particles_source[j];
                let other_species = u32(other.species);
                let force = forces[species * u32(options.species_count) + other_species];

                var r = vec2f(other.x, other.y) - particle_pos;

                if (looping_borders) {
                    if (abs(r.x) >= width * 0.5) {
                        r.x -= sign(r.x) * width;
                    }
                    if (abs(r.y) >= height * 0.5) {
                        r.y -= sign(r.y) * height;
                    }
                }

                let d = length(r);
                if (d > 0.0 && d < force.radius) {
                    let n = r / d;
                    total_force += force.strength * max(0.0, 1.0 - d / force.radius) * n;
                    total_force -= force.collision_strength * max(0.0, 1.0 - d / force.collision_radius) * n;
                }
            }
        }
    }

    particle.vx += total_force.x * options.dt;
    particle.vy += total_force.y * options.dt;

    particles_destination[id.x] = particle;
}
