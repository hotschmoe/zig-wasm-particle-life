//! GPU-side simulation: particle initialization, spatial binning, force
//! evaluation and integration. The CPU only records the dispatches.
//!
//! One step:
//!   1. count particles per bin            (clearBinSize, fillBinSize)
//!   2. inclusive prefix sum of the counts (prefixSumStep, log2(bins) times)
//!   3. counting-sort particles by bin     (clearBinSize, sortParticles)
//!   4. forces from the 3x3 bin neighbourhood on the sorted copy
//!   5. friction, mouse action and integration back into the main buffer

const std = @import("std");
const gpu = @import("../gpu.zig");
const shaders = @import("shaders.zig");
const system = @import("system.zig");
const types = @import("types.zig");

/// Must match `@workgroup_size` in every compute shader.
const workgroup_size = 64;

/// Edge length of a spatial bin. Must be at least the largest force radius.
pub const bin_size = 80.0;

/// Dynamic uniform offsets must be a multiple of `minUniformBufferOffsetAlignment`.
const uniform_stride = 256;

/// Largest number of prefix-sum passes: log2 of the bin count, rounded up to even.
const max_prefix_steps = 16;

/// Largest supported world edge; keeps the prefix-sum pass count bounded.
pub const max_world_size = 4096;

pub const Params = struct {
    particle_count: u32,
    species_count: u32,
    width: f32,
    height: f32,
};

pub const Physics = struct {
    particle_count: u32,
    bin_count: u32,
    prefix_steps: u32,

    particles: gpu.Buffer,
    species: gpu.Buffer,
    forces: gpu.Buffer,
    options: gpu.Buffer,
    seed: gpu.Buffer,

    clear_bins: gpu.ComputePipeline,
    fill_bins: gpu.ComputePipeline,
    prefix_sum: gpu.ComputePipeline,
    clear_sort: gpu.ComputePipeline,
    sort: gpu.ComputePipeline,
    compute_forces: gpu.ComputePipeline,
    advance: gpu.ComputePipeline,
    init_particles: gpu.ComputePipeline,

    particles_rw_group: gpu.BindGroup,
    particles_ro_group: gpu.BindGroup,
    options_group: gpu.BindGroup,
    seed_group: gpu.BindGroup,
    bins_group: gpu.BindGroup,
    /// Ping-pong pair: even passes read `bin_offsets`, odd passes read `bin_offsets_tmp`.
    prefix_groups: [2]gpu.BindGroup,
    sort_group: gpu.BindGroup,
    forces_group: gpu.BindGroup,

    pub fn init(pool: *gpu.Pool, params: Params) gpu.Error!Physics {
        const grid = gridSize(params.width, params.height);
        const bin_count = grid[0] * grid[1];
        const prefix_steps = prefixSteps(bin_count);
        std.debug.assert(prefix_steps <= max_prefix_steps);

        const particle_bytes = params.particle_count * @sizeOf(types.Particle);
        const offset_bytes = (bin_count + 1) * @sizeOf(u32);
        const storage: gpu.BufferUsage = .{ .storage = true, .copy_dst = true };
        const uniform: gpu.BufferUsage = .{ .uniform = true, .copy_dst = true };

        const particles = try pool.buffer(particle_bytes, storage);
        const particles_sorted = try pool.buffer(particle_bytes, storage);
        const species = try pool.buffer(params.species_count * @sizeOf(types.Species), storage);
        const forces = try pool.buffer(params.species_count * params.species_count * @sizeOf(types.Force), storage);
        const options = try pool.buffer(@sizeOf(types.Options), uniform);
        const seed = try pool.buffer(@sizeOf(u32), uniform);
        const bin_offsets = try pool.buffer(offset_bytes, storage);
        const bin_offsets_tmp = try pool.buffer(offset_bytes, storage);
        // At least one slot so the bind group below stays valid when no passes are needed.
        const steps = try pool.buffer(@max(prefix_steps, 1) * uniform_stride, uniform);
        writePrefixSteps(steps, prefix_steps);

        const compute: gpu.Stage = .{ .compute = true };
        const storage_layout = try pool.bindGroupLayout(compute, &.{.storage});
        const read_layout = try pool.bindGroupLayout(compute, &.{.read_only_storage});
        const uniform_layout = try pool.bindGroupLayout(compute, &.{.uniform});
        const prefix_layout = try pool.bindGroupLayout(compute, &.{ .read_only_storage, .storage, .uniform_dynamic });
        const sort_layout = try pool.bindGroupLayout(compute, &.{ .read_only_storage, .storage, .read_only_storage, .storage });
        const forces_layout = try pool.bindGroupLayout(compute, &.{ .read_only_storage, .storage, .read_only_storage, .read_only_storage });

        const binning = try pool.shaderModule(shaders.binning);
        const prefix_sum = try pool.shaderModule(shaders.prefix_sum);
        const sort = try pool.shaderModule(shaders.sort);
        const forces_module = try pool.shaderModule(shaders.forces);
        const advance = try pool.shaderModule(shaders.advance);
        const init_module = try pool.shaderModule(shaders.init);

        const bin_layouts = [_]gpu.BindGroupLayout{ read_layout, uniform_layout, storage_layout };
        const sort_layouts = [_]gpu.BindGroupLayout{ sort_layout, uniform_layout };

        return .{
            .particle_count = params.particle_count,
            .bin_count = bin_count,
            .prefix_steps = prefix_steps,
            .particles = particles,
            .species = species,
            .forces = forces,
            .options = options,
            .seed = seed,

            .clear_bins = try pool.computePipeline(binning, "clearBinSize", &bin_layouts),
            .fill_bins = try pool.computePipeline(binning, "fillBinSize", &bin_layouts),
            .prefix_sum = try pool.computePipeline(prefix_sum, "prefixSumStep", &.{prefix_layout}),
            .clear_sort = try pool.computePipeline(sort, "clearBinSize", &sort_layouts),
            .sort = try pool.computePipeline(sort, "sortParticles", &sort_layouts),
            .compute_forces = try pool.computePipeline(forces_module, "computeForces", &.{ forces_layout, uniform_layout }),
            .advance = try pool.computePipeline(advance, "particleAdvance", &.{ storage_layout, uniform_layout }),
            .init_particles = try pool.computePipeline(init_module, "initParticles", &.{ storage_layout, uniform_layout, uniform_layout }),

            .particles_rw_group = try pool.bindGroup(storage_layout, &.{.buffer(particles)}),
            .particles_ro_group = try pool.bindGroup(read_layout, &.{.buffer(particles)}),
            .options_group = try pool.bindGroup(uniform_layout, &.{.buffer(options)}),
            .seed_group = try pool.bindGroup(uniform_layout, &.{.buffer(seed)}),
            .bins_group = try pool.bindGroup(storage_layout, &.{.buffer(bin_offsets)}),
            .prefix_groups = .{
                try pool.bindGroup(prefix_layout, &.{ .buffer(bin_offsets), .buffer(bin_offsets_tmp), .bufferRange(steps, @sizeOf(u32)) }),
                try pool.bindGroup(prefix_layout, &.{ .buffer(bin_offsets_tmp), .buffer(bin_offsets), .bufferRange(steps, @sizeOf(u32)) }),
            },
            .sort_group = try pool.bindGroup(sort_layout, &.{ .buffer(particles), .buffer(particles_sorted), .buffer(bin_offsets), .buffer(bin_offsets_tmp) }),
            .forces_group = try pool.bindGroup(forces_layout, &.{ .buffer(particles_sorted), .buffer(particles), .buffer(bin_offsets), .buffer(forces) }),
        };
    }

    pub fn uploadOptions(physics: Physics, options: types.Options) void {
        gpu.writeValue(physics.options, types.Options, options);
    }

    /// Scatters particles uniformly with random velocities and species.
    pub fn scatter(physics: Physics, seed: u32) void {
        gpu.writeValue(physics.seed, u32, seed);

        const encoder = gpu.Encoder.create();
        const pass = encoder.beginComputePass();
        pass.setPipeline(physics.init_particles);
        pass.setBindGroup(0, physics.particles_rw_group);
        pass.setBindGroup(1, physics.options_group);
        pass.setBindGroup(2, physics.seed_group);
        pass.dispatch(workgroups(physics.particle_count));
        pass.end();
        encoder.submit();
    }

    /// Advances the simulation by one step using the options last uploaded.
    pub fn step(physics: Physics) void {
        const bin_groups = workgroups(physics.bin_count + 1);
        const particle_groups = workgroups(physics.particle_count);

        const encoder = gpu.Encoder.create();
        const pass = encoder.beginComputePass();

        pass.setPipeline(physics.clear_bins);
        pass.setBindGroup(0, physics.particles_ro_group);
        pass.setBindGroup(1, physics.options_group);
        pass.setBindGroup(2, physics.bins_group);
        pass.dispatch(bin_groups);

        pass.setPipeline(physics.fill_bins);
        pass.dispatch(particle_groups);

        pass.setPipeline(physics.prefix_sum);
        for (0..physics.prefix_steps) |i| {
            pass.setBindGroupOffset(0, physics.prefix_groups[i % 2], @intCast(i * uniform_stride));
            pass.dispatch(bin_groups);
        }

        pass.setPipeline(physics.clear_sort);
        pass.setBindGroup(0, physics.sort_group);
        pass.setBindGroup(1, physics.options_group);
        pass.dispatch(bin_groups);

        pass.setPipeline(physics.sort);
        pass.dispatch(particle_groups);

        pass.setPipeline(physics.compute_forces);
        pass.setBindGroup(0, physics.forces_group);
        pass.dispatch(particle_groups);

        pass.setPipeline(physics.advance);
        pass.setBindGroup(0, physics.particles_rw_group);
        pass.dispatch(particle_groups);

        pass.end();
        encoder.submit();
    }
};

fn workgroups(invocations: u32) u32 {
    return (invocations + workgroup_size - 1) / workgroup_size;
}

/// Bins per axis; matches `getBinInfo` in `shaders/common.wgsl`.
fn gridSize(width: f32, height: f32) [2]u32 {
    return .{
        @intFromFloat(@ceil(width / bin_size)),
        @intFromFloat(@ceil(height / bin_size)),
    };
}

/// A Hillis-Steele scan needs ceil(log2(n)) passes; the result is rounded up to
/// even so it ends in the buffer it started in.
fn prefixSteps(bin_count: u32) u32 {
    const log2: u32 = std.math.log2_int_ceil(u32, bin_count);
    return (log2 + 1) / 2 * 2;
}

/// Pass `i` reads its step size, `1 << i`, from the uniform at offset `i * uniform_stride`.
fn writePrefixSteps(buffer: gpu.Buffer, steps: u32) void {
    var data: [max_prefix_steps * uniform_stride / @sizeOf(u32)]u32 = @splat(0);
    for (0..steps) |i| data[i * uniform_stride / @sizeOf(u32)] = @as(u32, 1) << @intCast(i);
    gpu.writeBuffer(buffer, std.mem.sliceAsBytes(data[0 .. @max(steps, 1) * uniform_stride / @sizeOf(u32)]));
}

comptime {
    std.debug.assert(system.max_force_radius <= bin_size);
}
