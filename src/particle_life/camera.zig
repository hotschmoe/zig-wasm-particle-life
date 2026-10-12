//! Orthographic 2D camera. The extern layout is the uniform block read by the
//! particle vertex and fragment shaders.

const std = @import("std");

pub const Camera = extern struct {
    center_x: f32,
    center_y: f32,
    /// Half the visible world size.
    extent_x: f32,
    extent_y: f32,
    pixels_per_unit: f32,
    _pad: [3]f32 = @splat(0),

    /// Frames the whole `world_width` x `world_height` rectangle.
    pub fn fit(canvas_width: f32, canvas_height: f32, world_width: f32, world_height: f32) Camera {
        const aspect = canvas_width / canvas_height;
        const extent_x = if (world_width / world_height > aspect)
            world_width / 2.0
        else
            world_height / 2.0 * aspect;
        return .{
            .center_x = 0.0,
            .center_y = 0.0,
            .extent_x = extent_x,
            .extent_y = extent_x / aspect,
            .pixels_per_unit = canvas_width / (2.0 * extent_x),
        };
    }

    pub fn pan(camera: *Camera, dx_pixels: f32, dy_pixels: f32) void {
        const world_per_pixel = 1.0 / camera.pixels_per_unit;
        camera.center_x -= dx_pixels * world_per_pixel;
        camera.center_y += dy_pixels * world_per_pixel;
    }

    /// Scales the view by `factor` while keeping the world point under `ndc` fixed.
    pub fn zoom(camera: *Camera, factor: f32, ndc: [2]f32, canvas_width: f32) void {
        const anchor = camera.toWorld(ndc);
        camera.extent_x *= factor;
        camera.extent_y *= factor;
        camera.center_x = anchor[0] - ndc[0] * camera.extent_x;
        camera.center_y = anchor[1] - ndc[1] * camera.extent_y;
        camera.pixels_per_unit = canvas_width / (2.0 * camera.extent_x);
    }

    pub fn toWorld(camera: Camera, ndc: [2]f32) [2]f32 {
        return .{
            camera.center_x + ndc[0] * camera.extent_x,
            camera.center_y + ndc[1] * camera.extent_y,
        };
    }
};

/// Maps a pixel position (origin top-left) to normalized device coordinates.
pub fn pixelToNdc(x: f32, y: f32, canvas_width: f32, canvas_height: f32) [2]f32 {
    return .{
        x / canvas_width * 2.0 - 1.0,
        1.0 - y / canvas_height * 2.0,
    };
}

comptime {
    std.debug.assert(@sizeOf(Camera) == 32);
}
