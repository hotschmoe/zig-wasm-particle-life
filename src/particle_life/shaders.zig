//! WGSL sources, embedded and minified at compile time. The structs in
//! `shaders/common.wgsl` mirror `types.zig`.

const std = @import("std");

const common = @embedFile("shaders/common.wgsl") ++ "\n";

/// Entry points: `clearBinSize`, `fillBinSize`.
pub const binning = minify(common ++ @embedFile("shaders/binning.wgsl"));
/// Entry point: `prefixSumStep`.
pub const prefix_sum = minify(@embedFile("shaders/prefix_sum.wgsl"));
/// Entry points: `clearBinSize`, `sortParticles`.
pub const sort = minify(common ++ @embedFile("shaders/sort.wgsl"));
/// Entry point: `computeForces`.
pub const forces = minify(common ++ @embedFile("shaders/forces.wgsl"));
/// Entry point: `particleAdvance`.
pub const advance = minify(common ++ @embedFile("shaders/advance.wgsl"));
/// Entry point: `initParticles`.
pub const init = minify(common ++ @embedFile("shaders/init.wgsl"));
/// Entry points: `vertexGlow`/`fragmentGlow`, `vertexCircle`/`fragmentCircle`,
/// `vertexPoint`/`fragmentPoint`.
pub const particles = minify(@embedFile("shaders/particles.wgsl"));
/// Entry points: `vertexMain`, `fragmentMain`.
pub const compose = minify(@embedFile("shaders/compose.wgsl"));

/// Drops comments, indentation and blank lines. WGSL has no string literals and
/// newlines are plain whitespace, so this cannot change meaning; it roughly
/// halves the embedded shader bytes.
fn minify(comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(source.len * 40);
    comptime {
        var buffer: [source.len]u8 = undefined;
        var len: usize = 0;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |raw| {
            const code = if (std.mem.indexOf(u8, raw, "//")) |at| raw[0..at] else raw;
            const line = std.mem.trim(u8, code, " \t\r");
            if (line.len == 0) continue;
            @memcpy(buffer[len..][0..line.len], line);
            len += line.len;
            buffer[len] = '\n';
            len += 1;
        }
        const result = buffer[0..len].*;
        return &result;
    }
}
