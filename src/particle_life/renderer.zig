//! Draws the particles into an HDR target (additive glow plus circles or
//! points depending on zoom), then tone-maps and dithers onto the canvas.

const std = @import("std");
const gpu = @import("../gpu.zig");
const Camera = @import("camera.zig").Camera;
const shaders = @import("shaders.zig");

/// Below this zoom, circles are sub-pixel and cheaper point quads are used.
const point_zoom_threshold = 1.0;

/// Near-black rather than black so an empty target is distinguishable from a lost one.
const hdr_clear: gpu.ClearColor = .{ 0.001, 0.001, 0.001, 0.0 };
const canvas_clear: gpu.ClearColor = .{ 0.1, 0.0, 0.1, 1.0 };

pub const Renderer = struct {
    particle_count: u32,
    camera: gpu.Buffer,

    glow: gpu.RenderPipeline,
    circle: gpu.RenderPipeline,
    point: gpu.RenderPipeline,
    compose: gpu.RenderPipeline,

    particles_group: gpu.BindGroup,
    camera_group: gpu.BindGroup,
    compose_layout: gpu.BindGroupLayout,

    /// Objects tied to the canvas size, replaced on resize.
    target_pool: gpu.Pool = .{},
    width: u32,
    height: u32,
    target: gpu.TextureView,
    compose_group: gpu.BindGroup,
    blue_noise: ?gpu.TextureView,

    pub fn init(
        pool: *gpu.Pool,
        particles: gpu.Buffer,
        species: gpu.Buffer,
        particle_count: u32,
        canvas_width: u32,
        canvas_height: u32,
        blue_noise: ?gpu.TextureView,
    ) gpu.Error!Renderer {
        const camera = try pool.buffer(@sizeOf(Camera), .{ .uniform = true, .copy_dst = true });

        const particles_layout = try pool.bindGroupLayout(.{ .vertex = true }, &.{ .read_only_storage, .read_only_storage });
        // The fragment stage reads `pixels_per_unit` for anti-aliasing.
        const camera_layout = try pool.bindGroupLayout(.{ .vertex = true, .fragment = true }, &.{.uniform});
        const compose_layout = try pool.bindGroupLayout(.{ .fragment = true }, &.{ .texture, .texture });

        const particle_module = try pool.shaderModule(shaders.particles);
        const compose_module = try pool.shaderModule(shaders.compose);
        const layouts = [_]gpu.BindGroupLayout{ particles_layout, camera_layout };

        var renderer: Renderer = .{
            .particle_count = particle_count,
            .camera = camera,
            .glow = try pool.renderPipeline(.{
                .module = particle_module,
                .vertex_entry = "vertexGlow",
                .fragment_entry = "fragmentGlow",
                .layouts = &layouts,
                .target = .hdr_additive,
            }),
            .circle = try pool.renderPipeline(.{
                .module = particle_module,
                .vertex_entry = "vertexCircle",
                .fragment_entry = "fragmentCircle",
                .layouts = &layouts,
                .target = .hdr_additive,
            }),
            .point = try pool.renderPipeline(.{
                .module = particle_module,
                .vertex_entry = "vertexPoint",
                .fragment_entry = "fragmentPoint",
                .layouts = &layouts,
                .target = .hdr_additive,
            }),
            .compose = try pool.renderPipeline(.{
                .module = compose_module,
                .vertex_entry = "vertexMain",
                .fragment_entry = "fragmentMain",
                .layouts = &.{compose_layout},
                .target = .canvas,
            }),
            .particles_group = try pool.bindGroup(particles_layout, &.{ .buffer(particles), .buffer(species) }),
            .camera_group = try pool.bindGroup(camera_layout, &.{.buffer(camera)}),
            .compose_layout = compose_layout,
            .width = canvas_width,
            .height = canvas_height,
            .target = undefined,
            .compose_group = undefined,
            .blue_noise = blue_noise,
        };
        try renderer.createTarget();
        return renderer;
    }

    pub fn deinit(renderer: *Renderer) void {
        renderer.target_pool.deinit();
    }

    pub fn uploadCamera(renderer: Renderer, camera: Camera) void {
        gpu.writeValue(renderer.camera, Camera, camera);
    }

    /// Replaces the HDR target and the bind group that samples it.
    pub fn resize(renderer: *Renderer, width: u32, height: u32) gpu.Error!void {
        renderer.width = width;
        renderer.height = height;
        try renderer.recreateTarget();
    }

    pub fn setBlueNoise(renderer: *Renderer, view: gpu.TextureView) gpu.Error!void {
        renderer.blue_noise = view;
        try renderer.recreateTarget();
    }

    fn recreateTarget(renderer: *Renderer) gpu.Error!void {
        renderer.target_pool.deinit();
        try renderer.createTarget();
    }

    fn createTarget(renderer: *Renderer) gpu.Error!void {
        const pool = &renderer.target_pool;
        errdefer pool.deinit();
        renderer.target = try pool.textureView(try pool.renderTarget(renderer.width, renderer.height));
        // Without a noise texture the target itself stands in for the dither input.
        const noise = renderer.blue_noise orelse renderer.target;
        renderer.compose_group = try pool.bindGroup(
            renderer.compose_layout,
            &.{ .textureView(renderer.target), .textureView(noise) },
        );
    }

    pub fn draw(renderer: Renderer, pixels_per_unit: f32) void {
        const vertex_count = renderer.particle_count * 6;
        const encoder = gpu.Encoder.create();

        const hdr = encoder.beginRenderPass(renderer.target, hdr_clear);
        hdr.setBindGroup(0, renderer.particles_group);
        hdr.setBindGroup(1, renderer.camera_group);
        hdr.setPipeline(renderer.glow);
        hdr.draw(vertex_count);
        hdr.setPipeline(if (pixels_per_unit < point_zoom_threshold) renderer.point else renderer.circle);
        hdr.draw(vertex_count);
        hdr.end();

        const canvas = encoder.beginCanvasPass(canvas_clear);
        canvas.setPipeline(renderer.compose);
        canvas.setBindGroup(0, renderer.compose_group);
        canvas.draw(3);
        canvas.end();

        encoder.submit();
    }
};
