@group(0) @binding(0) var<storage, read> source: array<Particle>;
@group(0) @binding(1) var<storage, read_write> destination: array<Particle>;
@group(0) @binding(2) var<storage, read> bin_offset: array<u32>;
@group(0) @binding(3) var<storage, read_write> bin_size: array<atomic<u32>>;
@group(1) @binding(0) var<uniform> options: SimulationOptions;

@compute @workgroup_size(64)
fn clearBinSize(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&bin_size)) {
        return;
    }
    atomicStore(&bin_size[id.x], 0u);
}

@compute @workgroup_size(64)
fn sortParticles(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&source)) {
        return;
    }

    let particle = source[id.x];
    let bin_info = getBinInfo(vec2f(particle.x, particle.y), options);

    let new_index = bin_offset[bin_info.bin_index] + atomicAdd(&bin_size[bin_info.bin_index], 1);
    destination[new_index] = particle;
}
