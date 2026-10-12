@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(1) @binding(0) var<uniform> options: SimulationOptions;
@group(2) @binding(0) var<storage, read_write> bin_size: array<atomic<u32>>;

@compute @workgroup_size(64)
fn clearBinSize(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&bin_size)) {
        return;
    }
    atomicStore(&bin_size[id.x], 0u);
}

@compute @workgroup_size(64)
fn fillBinSize(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&particles)) {
        return;
    }

    let particle = particles[id.x];
    let bin_info = getBinInfo(vec2f(particle.x, particle.y), options);

    atomicAdd(&bin_size[bin_info.bin_index + 1], 1u);
}
