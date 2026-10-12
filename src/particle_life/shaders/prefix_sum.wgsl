@group(0) @binding(0) var<storage, read> source: array<u32>;
@group(0) @binding(1) var<storage, read_write> destination: array<u32>;
@group(0) @binding(2) var<uniform> step_size: u32;

@compute @workgroup_size(64)
fn prefixSumStep(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&source)) {
        return;
    }

    if (id.x < step_size) {
        destination[id.x] = source[id.x];
    } else {
        destination[id.x] = source[id.x - step_size] + source[id.x];
    }
}
