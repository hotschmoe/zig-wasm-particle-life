// Particle Life - Spatial Optimization Pipeline
//
// Implements spatial binning, prefix sum, and particle sorting for O(n×k) force computation

const std = @import("std");
const particle = @import("particle.zig");
const shaders = @import("shaders.zig");
const buffer = @import("../webgpu/buffer.zig");
const shader = @import("../webgpu/shader.zig");
const pipeline = @import("../webgpu/pipeline.zig");
const compute = @import("../webgpu/compute.zig");
const device = @import("../webgpu/device.zig");

/// Calculate grid size and bin count for spatial hashing (3D)
pub fn calculateGridSize(sim_width: f32, sim_height: f32, sim_depth: f32, bin_size: f32) struct { grid_x: u32, grid_y: u32, grid_z: u32, bin_count: u32 } {
    const grid_x = @as(u32, @intFromFloat(@ceil(sim_width / bin_size)));
    const grid_y = @as(u32, @intFromFloat(@ceil(sim_height / bin_size)));
    const grid_z = @as(u32, @intFromFloat(@ceil(sim_depth / bin_size)));
    return .{
        .grid_x = grid_x,
        .grid_y = grid_y,
        .grid_z = grid_z,
        .bin_count = grid_x * grid_y * grid_z,
    };
}

/// Calculate prefix sum iterations needed
pub fn calculatePrefixSumIterations(bin_count: u32) u32 {
    const log2_bins = std.math.log2_int_ceil(u32, bin_count);
    return ((log2_bins + 1) / 2) * 2; // Round up to even number
}

pub const SpatialPipeline = struct {
    // Shaders
    binning_shader: shader.ShaderModule,
    prefix_sum_shader: shader.ShaderModule,
    sort_shader: shader.ShaderModule,
    forces_shader: shader.ShaderModule,

    // Pipelines
    bin_clear_pipeline: pipeline.ComputePipeline,
    bin_fill_pipeline: pipeline.ComputePipeline,
    prefix_sum_pipeline: pipeline.ComputePipeline,
    sort_clear_pipeline: pipeline.ComputePipeline,
    sort_pipeline: pipeline.ComputePipeline,
    forces_pipeline: pipeline.ComputePipeline,

    // Bind group layouts
    particle_readonly_layout: pipeline.BindGroupLayout,
    options_layout: pipeline.BindGroupLayout,
    bin_size_layout: pipeline.BindGroupLayout,
    prefix_sum_layout: pipeline.BindGroupLayout,
    sort_layout: pipeline.BindGroupLayout,
    forces_layout: pipeline.BindGroupLayout,

    // Bind groups
    particle_readonly_group: pipeline.BindGroup,
    options_group: pipeline.BindGroup,
    bin_size_group: pipeline.BindGroup,
    prefix_sum_group_0: pipeline.BindGroup,
    prefix_sum_group_1: pipeline.BindGroup,
    sort_group: pipeline.BindGroup,
    forces_group: pipeline.BindGroup,

    // Additional buffers
    particle_temp_buffer: buffer.Buffer,
    bin_offset_buffer: buffer.Buffer,
    bin_offset_temp_buffer: buffer.Buffer,
    prefix_sum_step_buffer: buffer.Buffer,

    // Parameters
    bin_count: u32,
    prefix_sum_iterations: u32,

    pub fn init(
        particle_buffer: buffer.Buffer,
        particle_count: u32,
        species_buffer: buffer.Buffer,
        force_buffer: buffer.Buffer,
        options_buffer: buffer.Buffer,
        sim_width: f32,
        sim_height: f32,
        sim_depth: f32, // Added depth
        max_force_radius: f32,
    ) !SpatialPipeline {
        _ = particle_count; // Will use for initial buffer sizing if needed
        log("Setting up spatial optimization pipeline...");

        const grid = calculateGridSize(sim_width, sim_height, sim_depth, max_force_radius);
        const bin_count = grid.bin_count;
        const prefix_sum_iterations = calculatePrefixSumIterations(bin_count);

        logInt("  Grid X:", grid.grid_x);
        logInt("  Grid Y:", grid.grid_y);
        logInt("  Grid Z:", grid.grid_z);
        logInt("  Bin count:", bin_count);
        logInt("  Prefix sum iterations:", prefix_sum_iterations);

        // Create additional buffers
        // 3D particles are larger (32 bytes), but buffer size is calculated by stride * count, so correct.
        const particle_temp_buffer = buffer.createStorageBuffer(particle_buffer.size);
        const bin_offset_buffer = buffer.createStorageBuffer((bin_count + 1) * 4);
        const bin_offset_temp_buffer = buffer.createStorageBuffer((bin_count + 1) * 4);

        // Create prefix sum step size buffer
        // Each iteration needs a u32 at offset i*256 bytes (i*64 u32s)
        const prefix_sum_step_buffer = buffer.createUniformBuffer(prefix_sum_iterations * 256);
        var step_sizes: [2048]u32 = undefined; // Max 32 iterations * 64 u32s each = 2048
        @memset(&step_sizes, 0);

        for (0..prefix_sum_iterations) |i| {
            step_sizes[i * 64] = @as(u32, 1) << @intCast(i); // 2^i at each 256-byte offset
        }
        prefix_sum_step_buffer.writeTyped(u32, 0, step_sizes[0..(prefix_sum_iterations * 64)]);

        // Create shaders
        const binning_shader = shader.ShaderModule.create(shaders.spatial_binning);
        const prefix_sum_shader = shader.ShaderModule.create(shaders.prefix_sum);
        const sort_shader = shader.ShaderModule.create(shaders.particle_sort);
        const forces_shader = shader.ShaderModule.create(shaders.force_computation);

        // Create bind group layouts
        // Layout for particle read-only + species
        const particle_readonly_layout = createParticleReadonlyLayout();

        // Layout for simulation options
        const options_layout = createOptionsLayout();

        // Layout for bin size buffer
        const bin_size_layout = createBinSizeLayout();

        // Layout for prefix sum (source, dest, step_size with dynamic offset)
        const prefix_sum_layout = createPrefixSumLayout();

        // Layout for sorting
        const sort_layout = createSortLayout();

        // Layout for force computation
        const forces_layout = createForcesLayout();

        // Create bind groups
        const particle_readonly_group = createParticleReadonlyBindGroup(particle_readonly_layout, particle_buffer, species_buffer);
        const options_group = createOptionsBindGroup(options_layout, options_buffer);
        const bin_size_group = createBinSizeBindGroup(bin_size_layout, bin_offset_buffer);

        // Prefix sum bind groups (ping-pong between two)
        const prefix_sum_group_0 = createPrefixSumBindGroup(prefix_sum_layout, bin_offset_buffer, bin_offset_temp_buffer, prefix_sum_step_buffer);
        const prefix_sum_group_1 = createPrefixSumBindGroup(prefix_sum_layout, bin_offset_temp_buffer, bin_offset_buffer, prefix_sum_step_buffer);

        // Sort bind group
        const sort_group = createSortBindGroup(sort_layout, particle_buffer, particle_temp_buffer, bin_offset_buffer, bin_offset_temp_buffer);

        // Forces bind group
        const forces_group = createForcesBindGroup(forces_layout, particle_temp_buffer, particle_buffer, bin_offset_buffer, force_buffer);

        // Create all pipelines
        const bin_clear_pipeline = createBinClearPipeline(particle_readonly_layout, options_layout, bin_size_layout, binning_shader);
        const bin_fill_pipeline = createBinFillPipeline(particle_readonly_layout, options_layout, bin_size_layout, binning_shader);
        const prefix_sum_pipeline = createPrefixSumPipeline(prefix_sum_layout, prefix_sum_shader);
        const sort_clear_pipeline = createSortClearPipeline(sort_layout, options_layout, sort_shader);
        const sort_pipeline = createSortPipeline(sort_layout, options_layout, sort_shader);
        const forces_pipeline = createForcesPipeline(forces_layout, options_layout, forces_shader);

        log("✓ Spatial optimization pipeline created");

        return SpatialPipeline{
            .binning_shader = binning_shader,
            .prefix_sum_shader = prefix_sum_shader,
            .sort_shader = sort_shader,
            .forces_shader = forces_shader,
            .bin_clear_pipeline = bin_clear_pipeline,
            .bin_fill_pipeline = bin_fill_pipeline,
            .prefix_sum_pipeline = prefix_sum_pipeline,
            .sort_clear_pipeline = sort_clear_pipeline,
            .sort_pipeline = sort_pipeline,
            .forces_pipeline = forces_pipeline,
            .particle_readonly_layout = particle_readonly_layout,
            .options_layout = options_layout,
            .bin_size_layout = bin_size_layout,
            .prefix_sum_layout = prefix_sum_layout,
            .sort_layout = sort_layout,
            .forces_layout = forces_layout,
            .particle_readonly_group = particle_readonly_group,
            .options_group = options_group,
            .bin_size_group = bin_size_group,
            .prefix_sum_group_0 = prefix_sum_group_0,
            .prefix_sum_group_1 = prefix_sum_group_1,
            .sort_group = sort_group,
            .forces_group = forces_group,
            .particle_temp_buffer = particle_temp_buffer,
            .bin_offset_buffer = bin_offset_buffer,
            .bin_offset_temp_buffer = bin_offset_temp_buffer,
            .prefix_sum_step_buffer = prefix_sum_step_buffer,
            .bin_count = bin_count,
            .prefix_sum_iterations = prefix_sum_iterations,
        };
    }

    /// Returns the command encoder handle for chaining with advancement pass
    pub fn computeForces(self: *SpatialPipeline, particle_count: u32, particle_buffer_handle: u32, particle_temp_buffer_handle: u32) u32 {
        const encoder = compute.CommandEncoder.create();

        // Copy particles to temp buffer BEFORE starting compute pass
        js_webgpu_copy_buffer_to_buffer_in_encoder(encoder.handle.id, particle_buffer_handle, 0, particle_temp_buffer_handle, 0, particle_count * @sizeOf(particle.Particle));

        // Start binning compute pass
        const binning_pass = encoder.beginComputePass();

        // 1. Clear bin sizes
        binning_pass.setPipeline(self.bin_clear_pipeline);
        binning_pass.setBindGroup(0, self.particle_readonly_group);
        binning_pass.setBindGroup(1, self.options_group);
        binning_pass.setBindGroup(2, self.bin_size_group);
        binning_pass.dispatch((self.bin_count + 1 + 63) / 64, 1, 1);

        // 2. Fill bin sizes
        binning_pass.setPipeline(self.bin_fill_pipeline);
        binning_pass.dispatch((particle_count + 63) / 64, 1, 1);

        // 3. Prefix sum (ping-pong between buffers)
        binning_pass.setPipeline(self.prefix_sum_pipeline);
        for (0..self.prefix_sum_iterations) |i| {
            const group = if (i % 2 == 0) self.prefix_sum_group_0 else self.prefix_sum_group_1;
            const offset = @as(u32, @intCast(i)) * 256;
            js_webgpu_compute_pass_set_bind_group_with_offset(binning_pass.handle.id, 0, group.handle.id, offset);
            binning_pass.dispatch((self.bin_count + 1 + 63) / 64, 1, 1);
        }

        // 4. Clear bin sizes for sorting
        binning_pass.setPipeline(self.sort_clear_pipeline);
        binning_pass.setBindGroup(0, self.sort_group);
        binning_pass.setBindGroup(1, self.options_group);
        binning_pass.dispatch((self.bin_count + 1 + 63) / 64, 1, 1);

        // 5. Sort particles by bins
        binning_pass.setPipeline(self.sort_pipeline);
        binning_pass.dispatch((particle_count + 63) / 64, 1, 1);

        binning_pass.end();

        // 6. Force computation (separate pass)
        const forces_pass = encoder.beginComputePass();
        forces_pass.setPipeline(self.forces_pipeline);
        forces_pass.setBindGroup(0, self.forces_group);
        forces_pass.setBindGroup(1, self.options_group);
        forces_pass.dispatch((particle_count + 63) / 64, 1, 1);
        forces_pass.end();

        // Return encoder handle for caller to add advancement pass
        return encoder.handle.id;
    }

    pub fn deinit(self: *SpatialPipeline) void {
        self.particle_temp_buffer.destroy();
        self.bin_offset_buffer.destroy();
        self.bin_offset_temp_buffer.destroy();
        self.prefix_sum_step_buffer.destroy();
    }
};

// Helper functions to create layouts and bind groups

fn createParticleReadonlyLayout() pipeline.BindGroupLayout {
    const entries = [_]pipeline.BindGroupLayoutEntry{
        pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
        pipeline.BindGroupLayoutEntry.init(1, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
    };
    return pipeline.BindGroupLayout.create(&entries);
}

fn createOptionsLayout() pipeline.BindGroupLayout {
    const entries = [_]pipeline.BindGroupLayoutEntry{
        pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .uniform),
    };
    return pipeline.BindGroupLayout.create(&entries);
}

fn createBinSizeLayout() pipeline.BindGroupLayout {
    const entries = [_]pipeline.BindGroupLayoutEntry{
        pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .storage),
    };
    return pipeline.BindGroupLayout.create(&entries);
}

fn createPrefixSumLayout() pipeline.BindGroupLayout {
    const entries = [_]pipeline.BindGroupLayoutEntry{
        pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
        pipeline.BindGroupLayoutEntry.init(1, pipeline.ShaderVisibility.COMPUTE, .storage),
        pipeline.BindGroupLayoutEntry.init(2, pipeline.ShaderVisibility.COMPUTE, .uniform).withDynamicOffset(),
    };
    return pipeline.BindGroupLayout.create(&entries);
}

fn createSortLayout() pipeline.BindGroupLayout {
    const entries = [_]pipeline.BindGroupLayoutEntry{
        pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
        pipeline.BindGroupLayoutEntry.init(1, pipeline.ShaderVisibility.COMPUTE, .storage),
        pipeline.BindGroupLayoutEntry.init(2, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
        pipeline.BindGroupLayoutEntry.init(3, pipeline.ShaderVisibility.COMPUTE, .storage),
    };
    return pipeline.BindGroupLayout.create(&entries);
}

fn createForcesLayout() pipeline.BindGroupLayout {
    const entries = [_]pipeline.BindGroupLayoutEntry{
        pipeline.BindGroupLayoutEntry.init(0, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
        pipeline.BindGroupLayoutEntry.init(1, pipeline.ShaderVisibility.COMPUTE, .storage),
        pipeline.BindGroupLayoutEntry.init(2, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
        pipeline.BindGroupLayoutEntry.init(3, pipeline.ShaderVisibility.COMPUTE, .read_only_storage),
    };
    return pipeline.BindGroupLayout.create(&entries);
}

fn createParticleReadonlyBindGroup(layout: pipeline.BindGroupLayout, particle_buf: buffer.Buffer, species_buf: buffer.Buffer) pipeline.BindGroup {
    const entries = [_]pipeline.BindGroupEntry{
        pipeline.BindGroupEntry.initFull(0, particle_buf.handle, particle_buf.size),
        pipeline.BindGroupEntry.initFull(1, species_buf.handle, species_buf.size),
    };
    return pipeline.BindGroup.create(layout, &entries);
}

fn createOptionsBindGroup(layout: pipeline.BindGroupLayout, options_buf: buffer.Buffer) pipeline.BindGroup {
    const entries = [_]pipeline.BindGroupEntry{
        pipeline.BindGroupEntry.initFull(0, options_buf.handle, options_buf.size),
    };
    return pipeline.BindGroup.create(layout, &entries);
}

fn createBinSizeBindGroup(layout: pipeline.BindGroupLayout, bin_offset_buf: buffer.Buffer) pipeline.BindGroup {
    const entries = [_]pipeline.BindGroupEntry{
        pipeline.BindGroupEntry.initFull(0, bin_offset_buf.handle, bin_offset_buf.size),
    };
    return pipeline.BindGroup.create(layout, &entries);
}

fn createPrefixSumBindGroup(layout: pipeline.BindGroupLayout, source_buf: buffer.Buffer, dest_buf: buffer.Buffer, step_buf: buffer.Buffer) pipeline.BindGroup {
    const entries = [_]pipeline.BindGroupEntry{
        pipeline.BindGroupEntry.initFull(0, source_buf.handle, source_buf.size),
        pipeline.BindGroupEntry.initFull(1, dest_buf.handle, dest_buf.size),
        pipeline.BindGroupEntry.init(2, step_buf.handle, 0, 4), // Single u32
    };
    return pipeline.BindGroup.create(layout, &entries);
}

fn createSortBindGroup(layout: pipeline.BindGroupLayout, particle_buf: buffer.Buffer, temp_buf: buffer.Buffer, offset_buf: buffer.Buffer, offset_temp_buf: buffer.Buffer) pipeline.BindGroup {
    const entries = [_]pipeline.BindGroupEntry{
        pipeline.BindGroupEntry.initFull(0, particle_buf.handle, particle_buf.size),
        pipeline.BindGroupEntry.initFull(1, temp_buf.handle, temp_buf.size),
        pipeline.BindGroupEntry.initFull(2, offset_buf.handle, offset_buf.size),
        pipeline.BindGroupEntry.initFull(3, offset_temp_buf.handle, offset_temp_buf.size),
    };
    return pipeline.BindGroup.create(layout, &entries);
}

fn createForcesBindGroup(layout: pipeline.BindGroupLayout, temp_buf: buffer.Buffer, particle_buf: buffer.Buffer, offset_buf: buffer.Buffer, force_buf: buffer.Buffer) pipeline.BindGroup {
    const entries = [_]pipeline.BindGroupEntry{
        pipeline.BindGroupEntry.initFull(0, temp_buf.handle, temp_buf.size),
        pipeline.BindGroupEntry.initFull(1, particle_buf.handle, particle_buf.size),
        pipeline.BindGroupEntry.initFull(2, offset_buf.handle, offset_buf.size),
        pipeline.BindGroupEntry.initFull(3, force_buf.handle, force_buf.size),
    };
    return pipeline.BindGroup.create(layout, &entries);
}

fn createBinClearPipeline(particle_layout: pipeline.BindGroupLayout, options_layout: pipeline.BindGroupLayout, bin_layout: pipeline.BindGroupLayout, binning_shader: shader.ShaderModule) pipeline.ComputePipeline {
    const layouts = [_]pipeline.BindGroupLayout{ particle_layout, options_layout, bin_layout };
    const pipeline_layout = pipeline.PipelineLayout.create(&layouts);
    return pipeline.ComputePipeline.create(pipeline_layout, binning_shader, "clearBinSize");
}

fn createBinFillPipeline(particle_layout: pipeline.BindGroupLayout, options_layout: pipeline.BindGroupLayout, bin_layout: pipeline.BindGroupLayout, binning_shader: shader.ShaderModule) pipeline.ComputePipeline {
    const layouts = [_]pipeline.BindGroupLayout{ particle_layout, options_layout, bin_layout };
    const pipeline_layout = pipeline.PipelineLayout.create(&layouts);
    return pipeline.ComputePipeline.create(pipeline_layout, binning_shader, "fillBinSize");
}

fn createPrefixSumPipeline(prefix_layout: pipeline.BindGroupLayout, prefix_shader: shader.ShaderModule) pipeline.ComputePipeline {
    const layouts = [_]pipeline.BindGroupLayout{prefix_layout};
    const pipeline_layout = pipeline.PipelineLayout.create(&layouts);
    return pipeline.ComputePipeline.create(pipeline_layout, prefix_shader, "prefixSumStep");
}

fn createSortClearPipeline(sort_layout: pipeline.BindGroupLayout, options_layout: pipeline.BindGroupLayout, sort_shader: shader.ShaderModule) pipeline.ComputePipeline {
    const layouts = [_]pipeline.BindGroupLayout{ sort_layout, options_layout };
    const pipeline_layout = pipeline.PipelineLayout.create(&layouts);
    return pipeline.ComputePipeline.create(pipeline_layout, sort_shader, "clearBinSize");
}

fn createSortPipeline(sort_layout: pipeline.BindGroupLayout, options_layout: pipeline.BindGroupLayout, sort_shader: shader.ShaderModule) pipeline.ComputePipeline {
    const layouts = [_]pipeline.BindGroupLayout{ sort_layout, options_layout };
    const pipeline_layout = pipeline.PipelineLayout.create(&layouts);
    return pipeline.ComputePipeline.create(pipeline_layout, sort_shader, "sortParticles");
}

fn createForcesPipeline(forces_layout: pipeline.BindGroupLayout, options_layout: pipeline.BindGroupLayout, forces_shader: shader.ShaderModule) pipeline.ComputePipeline {
    const layouts = [_]pipeline.BindGroupLayout{ forces_layout, options_layout };
    const pipeline_layout = pipeline.PipelineLayout.create(&layouts);
    return pipeline.ComputePipeline.create(pipeline_layout, forces_shader, "computeForces");
}

fn log(comptime msg: []const u8) void {
    js_console_log(msg.ptr, msg.len);
}

fn logInt(comptime prefix: []const u8, value: u32) void {
    var buf: [64]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{s} {d}", .{ prefix, value }) catch "Error";
    js_console_log(str.ptr, str.len);
}

extern fn js_console_log(ptr: [*]const u8, len: usize) void;
extern fn js_webgpu_copy_buffer_to_buffer_in_encoder(encoder: u32, src: u32, src_offset: u64, dst: u32, dst_offset: u64, size: u64) void;
extern fn js_webgpu_compute_pass_set_bind_group_with_offset(pass: u32, index: u32, bind_group: u32, offset: u32) void;
