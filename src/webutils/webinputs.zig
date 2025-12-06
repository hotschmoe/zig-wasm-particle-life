const std = @import("std");

// Global input state
pub const InputState = struct {
    // Mouse/Touch state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    mouse_initialized: bool = false,
    mouse_down: bool = false, // LMB - attract particles
    mouse_right_down: bool = false, // RMB without shift - pan

    // Camera control
    zoom_delta: f32 = 0,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    rotate_x: f32 = 0, // Rotation around vertical axis (yaw)
    rotate_y: f32 = 0, // Rotation around horizontal axis (pitch)

    // Simulation options
    friction: f32 = 10.0, // Matches reference default
    time_step: f32 = 0.01,
    force_strength: f32 = 1.0,
    looping_borders: bool = true,
    central_force: f32 = 0.0,
    symmetric_forces: bool = false,

    pub fn resetPerFrame(self: *InputState) void {
        self.zoom_delta = 0;
        self.pan_x = 0;
        self.pan_y = 0;
        self.rotate_x = 0;
        self.rotate_y = 0;
        self.mouse_dx = 0;
        self.mouse_dy = 0;
    }
};

pub var state = InputState{};

// FFI Exports

export fn setMousePosition(x: f32, y: f32) void {
    if (state.mouse_initialized) {
        state.mouse_dx += x - state.mouse_x;
        state.mouse_dy += y - state.mouse_y;
    } else {
        state.mouse_initialized = true;
        state.mouse_dx = 0;
        state.mouse_dy = 0;
    }

    state.mouse_x = x;
    state.mouse_y = y;
}

export fn setMouseDown(is_down: bool) void {
    state.mouse_down = is_down;
}

export fn setMouseRightDown(is_down: bool) void {
    state.mouse_right_down = is_down;
}

export fn setZoom(delta: f32) void {
    state.zoom_delta = delta;
}

export fn setPan(dx: f32, dy: f32) void {
    state.pan_x = dx;
    state.pan_y = dy;
}

export fn setRotation(dx: f32, dy: f32) void {
    state.rotate_x = dx;
    state.rotate_y = dy;
}

export fn setSimOption(key: u32, value: f32) void {
    switch (key) {
        0 => state.friction = value,
        1 => state.time_step = value,
        2 => state.force_strength = value,
        3 => state.looping_borders = (value > 0.5),
        4 => state.central_force = value,
        5 => state.symmetric_forces = (value > 0.5),
        else => {},
    }
}
