//! Pointer and control state pushed from the page, consumed once per frame.

pub const Input = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    mouse_seen: bool = false,
    mouse_down: bool = false,
    mouse_right_down: bool = false,

    zoom_delta: f32 = 0,
    pan_x: f32 = 0,
    pan_y: f32 = 0,

    pub fn moveMouse(input: *Input, x: f32, y: f32) void {
        if (input.mouse_seen) {
            input.mouse_dx += x - input.mouse_x;
            input.mouse_dy += y - input.mouse_y;
        }
        input.mouse_seen = true;
        input.mouse_x = x;
        input.mouse_y = y;
    }

    /// Clears the deltas accumulated since the last frame.
    pub fn endFrame(input: *Input) void {
        input.zoom_delta = 0;
        input.pan_x = 0;
        input.pan_y = 0;
        input.mouse_dx = 0;
        input.mouse_dy = 0;
    }
};

/// Live-tunable simulation parameters.
pub const Settings = struct {
    friction: f32 = 10.0,
    looping_borders: bool = true,
    central_force: f32 = 0.0,
    symmetric_forces: bool = false,
};
