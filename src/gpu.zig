//! WebGPU bindings.
//!
//! The GPU objects live in a handle table owned by `web/main.js`; Zig only ever
//! sees 32-bit ids. Each kind of object gets its own non-exhaustive enum so
//! handles cannot be mixed up, while the extern signatures stay plain `u32`.
//! Long-lived objects are created through a `Pool` and released together.

const std = @import("std");

pub const Error = error{
    /// The host rejected the request and returned the null handle.
    GpuObjectFailed,
    PoolFull,
};

pub const Buffer = enum(u32) { _ };
pub const ShaderModule = enum(u32) { _ };
pub const BindGroupLayout = enum(u32) { _ };
pub const BindGroup = enum(u32) { _ };
pub const ComputePipeline = enum(u32) { _ };
pub const RenderPipeline = enum(u32) { _ };
pub const Texture = enum(u32) { _ };
pub const TextureView = enum(u32) { _ };

/// Mirrors `GPUBufferUsage`.
pub const BufferUsage = packed struct(u32) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _: u22 = 0,
};

/// Mirrors `GPUShaderStage`.
pub const Stage = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _: u29 = 0,
};

/// Binding types a layout can declare. Bindings are numbered by position.
pub const BindingKind = enum(u32) {
    uniform,
    storage,
    read_only_storage,
    /// A uniform buffer bound with a dynamic offset.
    uniform_dynamic,
    /// A non-filterable float 2D texture.
    texture,
};

/// One resource of a bind group; the position in the entry slice is the binding index.
pub const BindEntry = extern struct {
    /// A buffer or texture view handle.
    resource: u32,
    /// Bytes of the buffer to bind; zero binds the whole buffer.
    size: u32,

    pub fn buffer(handle: Buffer) BindEntry {
        return .{ .resource = @backingInt(handle), .size = 0 };
    }

    pub fn bufferRange(handle: Buffer, size: u32) BindEntry {
        return .{ .resource = @backingInt(handle), .size = size };
    }

    pub fn textureView(handle: TextureView) BindEntry {
        return .{ .resource = @backingInt(handle), .size = 0 };
    }
};

/// Render target configuration of a pipeline.
pub const PipelineTarget = enum(u32) {
    /// rgba16float with additive blending, for accumulating particles.
    hdr_additive,
    /// The canvas format, opaque.
    canvas,
};

pub const RenderPipelineDesc = struct {
    module: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    layouts: []const BindGroupLayout,
    target: PipelineTarget,
};

/// Owns a group of GPU objects and releases them together, newest first.
pub const Pool = struct {
    const capacity = 64;

    ids: [capacity]u32 = undefined,
    len: usize = 0,

    pub fn deinit(pool: *Pool) void {
        while (pool.len > 0) {
            pool.len -= 1;
            js.release(pool.ids[pool.len]);
        }
    }

    fn adopt(pool: *Pool, comptime Handle: type, raw: u32) Error!Handle {
        if (raw == 0) return error.GpuObjectFailed;
        if (pool.len == capacity) {
            js.release(raw);
            return error.PoolFull;
        }
        pool.ids[pool.len] = raw;
        pool.len += 1;
        return @fromBackingInt(@intCast(raw));
    }

    pub fn buffer(pool: *Pool, size: u32, usage: BufferUsage) Error!Buffer {
        return pool.adopt(Buffer, js.createBuffer(size, @bitCast(usage)));
    }

    pub fn shaderModule(pool: *Pool, wgsl: []const u8) Error!ShaderModule {
        return pool.adopt(ShaderModule, js.createShaderModule(wgsl.ptr, wgsl.len));
    }

    pub fn bindGroupLayout(pool: *Pool, stage: Stage, kinds: []const BindingKind) Error!BindGroupLayout {
        return pool.adopt(BindGroupLayout, js.createBindGroupLayout(@bitCast(stage), kinds.ptr, kinds.len));
    }

    pub fn bindGroup(pool: *Pool, layout: BindGroupLayout, entries: []const BindEntry) Error!BindGroup {
        return pool.adopt(BindGroup, js.createBindGroup(@backingInt(layout), entries.ptr, entries.len));
    }

    pub fn computePipeline(
        pool: *Pool,
        module: ShaderModule,
        entry: []const u8,
        layouts: []const BindGroupLayout,
    ) Error!ComputePipeline {
        const raw = js.createComputePipeline(@backingInt(module), entry.ptr, entry.len, layouts.ptr, layouts.len);
        return pool.adopt(ComputePipeline, raw);
    }

    pub fn renderPipeline(pool: *Pool, desc: RenderPipelineDesc) Error!RenderPipeline {
        const raw = js.createRenderPipeline(
            @backingInt(desc.module),
            desc.vertex_entry.ptr,
            desc.vertex_entry.len,
            desc.fragment_entry.ptr,
            desc.fragment_entry.len,
            desc.layouts.ptr,
            desc.layouts.len,
            desc.target,
        );
        return pool.adopt(RenderPipeline, raw);
    }

    /// An rgba16float 2D texture usable as a render attachment and for sampling.
    pub fn renderTarget(pool: *Pool, width: u32, height: u32) Error!Texture {
        return pool.adopt(Texture, js.createRenderTarget(width, height));
    }

    pub fn textureView(pool: *Pool, texture: Texture) Error!TextureView {
        return pool.adopt(TextureView, js.createTextureView(@backingInt(texture)));
    }
};

pub fn writeBuffer(buffer: Buffer, bytes: []const u8) void {
    js.writeBuffer(@backingInt(buffer), bytes.ptr, bytes.len);
}

/// Uploads one value, e.g. a uniform struct.
pub fn writeValue(buffer: Buffer, comptime T: type, value: T) void {
    writeBuffer(buffer, std.mem.asBytes(&value));
}

pub const ClearColor = [4]f32;

/// A command encoder. Passes and the encoder itself are consumed by `end` and `submit`.
pub const Encoder = enum(u32) {
    _,

    pub fn create() Encoder {
        return @fromBackingInt(@intCast(js.createEncoder()));
    }

    pub fn beginComputePass(encoder: Encoder) ComputePass {
        return @fromBackingInt(@intCast(js.beginComputePass(@backingInt(encoder))));
    }

    pub fn beginRenderPass(encoder: Encoder, target: TextureView, clear: ClearColor) RenderPass {
        return @fromBackingInt(@intCast(js.beginRenderPass(@backingInt(encoder), @backingInt(target), clear[0], clear[1], clear[2], clear[3])));
    }

    pub fn beginCanvasPass(encoder: Encoder, clear: ClearColor) RenderPass {
        return @fromBackingInt(@intCast(js.beginCanvasPass(@backingInt(encoder), clear[0], clear[1], clear[2], clear[3])));
    }

    /// Finishes the encoder and submits it to the queue.
    pub fn submit(encoder: Encoder) void {
        js.submit(@backingInt(encoder));
    }
};

pub const ComputePass = enum(u32) {
    _,

    pub fn setPipeline(pass: ComputePass, pipeline: ComputePipeline) void {
        js.passSetPipeline(@backingInt(pass), @backingInt(pipeline));
    }

    pub fn setBindGroup(pass: ComputePass, index: u32, group: BindGroup) void {
        js.passSetBindGroup(@backingInt(pass), index, @backingInt(group));
    }

    pub fn setBindGroupOffset(pass: ComputePass, index: u32, group: BindGroup, offset: u32) void {
        js.passSetBindGroupOffset(@backingInt(pass), index, @backingInt(group), offset);
    }

    pub fn dispatch(pass: ComputePass, workgroups: u32) void {
        js.dispatch(@backingInt(pass), workgroups);
    }

    pub fn end(pass: ComputePass) void {
        js.passEnd(@backingInt(pass));
    }
};

pub const RenderPass = enum(u32) {
    _,

    pub fn setPipeline(pass: RenderPass, pipeline: RenderPipeline) void {
        js.passSetPipeline(@backingInt(pass), @backingInt(pipeline));
    }

    pub fn setBindGroup(pass: RenderPass, index: u32, group: BindGroup) void {
        js.passSetBindGroup(@backingInt(pass), index, @backingInt(group));
    }

    pub fn draw(pass: RenderPass, vertex_count: u32) void {
        js.draw(@backingInt(pass), vertex_count);
    }

    pub fn end(pass: RenderPass) void {
        js.passEnd(@backingInt(pass));
    }
};

const js = struct {
    extern "gpu" fn createBuffer(size: u32, usage: u32) u32;
    extern "gpu" fn writeBuffer(buffer: u32, ptr: [*]const u8, len: usize) void;
    extern "gpu" fn createShaderModule(ptr: [*]const u8, len: usize) u32;
    extern "gpu" fn createBindGroupLayout(stage: u32, kinds: [*]const BindingKind, len: usize) u32;
    extern "gpu" fn createBindGroup(layout: u32, entries: [*]const BindEntry, len: usize) u32;
    extern "gpu" fn createComputePipeline(
        module: u32,
        entry_ptr: [*]const u8,
        entry_len: usize,
        layouts: [*]const BindGroupLayout,
        layouts_len: usize,
    ) u32;
    extern "gpu" fn createRenderPipeline(
        module: u32,
        vertex_ptr: [*]const u8,
        vertex_len: usize,
        fragment_ptr: [*]const u8,
        fragment_len: usize,
        layouts: [*]const BindGroupLayout,
        layouts_len: usize,
        target: PipelineTarget,
    ) u32;
    extern "gpu" fn createRenderTarget(width: u32, height: u32) u32;
    extern "gpu" fn createTextureView(texture: u32) u32;
    extern "gpu" fn release(handle: u32) void;

    extern "gpu" fn createEncoder() u32;
    extern "gpu" fn beginComputePass(encoder: u32) u32;
    extern "gpu" fn beginRenderPass(encoder: u32, view: u32, r: f32, g: f32, b: f32, a: f32) u32;
    extern "gpu" fn beginCanvasPass(encoder: u32, r: f32, g: f32, b: f32, a: f32) u32;
    extern "gpu" fn submit(encoder: u32) void;

    extern "gpu" fn passSetPipeline(pass: u32, pipeline: u32) void;
    extern "gpu" fn passSetBindGroup(pass: u32, index: u32, group: u32) void;
    extern "gpu" fn passSetBindGroupOffset(pass: u32, index: u32, group: u32, offset: u32) void;
    extern "gpu" fn dispatch(pass: u32, workgroups: u32) void;
    extern "gpu" fn draw(pass: u32, vertex_count: u32) void;
    extern "gpu" fn passEnd(pass: u32) void;
};
