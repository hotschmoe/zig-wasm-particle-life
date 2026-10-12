//! Random species colors and force matrices, generated on the CPU because they
//! are tiny: at most `max_species`^2 entries.

const std = @import("std");
const types = @import("types.zig");

pub const max_species = 16;

/// Upper bound of any generated force radius; the grid bin size must cover it.
pub const max_force_radius = 32.0;

/// splitmix32-style generator; fixed seeds reproduce the same system.
pub const Rng = struct {
    state: u32,

    pub fn init(seed: u32) Rng {
        return .{ .state = seed };
    }

    pub fn nextU32(rng: *Rng) u32 {
        rng.state +%= 0x9e3779b9;
        var t = rng.state ^ (rng.state >> 16);
        t *%= 0x21f0aaad;
        t ^= t >> 15;
        t *%= 0x735a2d97;
        t ^= t >> 15;
        return t;
    }

    /// Uniform in [0, 1].
    pub fn next(rng: *Rng) f32 {
        return @as(f32, @floatFromInt(rng.nextU32())) / 4294967296.0;
    }
};

/// Gamma-corrected random colors, matching the reference demo.
pub fn generateSpecies(species: []types.Species, rng: *Rng) void {
    for (species) |*s| {
        var color: [4]f32 = undefined;
        for (color[0..3]) |*channel| {
            channel.* = std.math.pow(f32, 0.25 + rng.next() * 0.75, 2.2);
        }
        color[3] = 1.0;
        s.* = .{ .color = color };
    }
}

/// Fills a row-major `n` x `n` matrix; entry `i * n + j` is the force species
/// `j` exerts on species `i`. With `symmetric`, `[i][j]` and `[j][i]` are averaged.
pub fn generateForces(forces: []types.Force, n: usize, rng: *Rng, symmetric: bool) void {
    const max_strength = 100.0;
    std.debug.assert(forces.len == n * n);

    for (forces) |*f| {
        const magnitude = max_strength * (0.25 + 0.75 * rng.next());
        const strength = if (rng.next() < 0.5) magnitude else -magnitude;
        const collision_strength = (5.0 + 15.0 * rng.next()) * @abs(strength);
        const radius = 2.0 + rng.next() * (max_force_radius - 2.0);
        const collision_radius = rng.next() * 0.5 * radius;
        f.* = .{
            .strength = strength,
            .radius = radius,
            .collision_strength = collision_strength,
            .collision_radius = collision_radius,
        };
    }

    if (!symmetric) return;
    for (0..n) |i| {
        for (i + 1..n) |j| {
            const a = &forces[i * n + j];
            const b = &forces[j * n + i];
            const mean: types.Force = .{
                .strength = (a.strength + b.strength) / 2.0,
                .radius = (a.radius + b.radius) / 2.0,
                .collision_strength = (a.collision_strength + b.collision_strength) / 2.0,
                .collision_radius = (a.collision_radius + b.collision_radius) / 2.0,
            };
            a.* = mean;
            b.* = mean;
        }
    }
}
