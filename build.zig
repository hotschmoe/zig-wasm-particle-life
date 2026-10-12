const std = @import("std");
const builtin = @import("builtin");

// WebGPU FFI Template - Build script for Zig + WASM
pub fn build(b: *std.Build) void {
    // WebAssembly target configuration
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Optimization mode - default to ReleaseSmall for smallest binary size
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    // Build Options
    const options = b.addOptions();
    options.addOption(i64, "build_timestamp", std.Io.Timestamp.now(b.graph.io, .real).toSeconds());

    // Create a module for the WASM code
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = true, // Strip debug info to reduce size
    });
    root_module.addOptions("build_options", options);

    // Create WebAssembly executable
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = root_module,
    });

    // Critical WASM settings for FFI
    exe.rdynamic = true; // Export all functions marked with 'export'
    exe.entry = .disabled; // No main() entry point - JS will call our exports
    exe.export_memory = true; // Share memory between WASM and JS

    // Configure WASM memory size (16MB initial, 512MB max)
    exe.stack_size = 32 * 1024 * 1024; // 32MB stack (supports up to 1,048,576 particles)
    exe.initial_memory = 64 * 1024 * 1024; // 64MB (1024 pages * 64KB)
    exe.max_memory = 512 * 1024 * 1024; // 512MB (8192 pages * 64KB)

    // Standard install (zig-out/bin) - kept for reference but not primary
    b.installArtifact(exe);

    // --- Dev Step: Build to web/ ---
    const dev_step = b.step("dev", "Build WASM to web/ directory");

    const install_dev_wasm = b.addInstallFile(exe.getEmittedBin(), "../web/app.wasm");
    dev_step.dependOn(&install_dev_wasm.step);

    // --- Deploy Step: Build to dist/ ---
    const deploy_step = b.step("deploy", "Build WASM and copy files to dist/");

    // Clean and create dist directory
    const clean_dist = b.addSystemCommand(if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", "if", "exist", "dist", "rd", "/s", "/q", "dist" }
    else
        &[_][]const u8{ "rm", "-rf", "dist" });

    const make_dist = b.addSystemCommand(if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd", "/c", "if", "not", "exist", "dist", "mkdir", "dist" }
    else
        &[_][]const u8{ "mkdir", "-p", "dist" });
    make_dist.step.dependOn(&clean_dist.step);

    // Copy WASM file to dist/
    const install_deploy_wasm = b.addInstallFile(exe.getEmittedBin(), "../dist/app.wasm");
    install_deploy_wasm.step.dependOn(&make_dist.step);
    deploy_step.dependOn(&install_deploy_wasm.step);

    // Copy web assets (HTML, JS, etc.) to dist/
    const copy_web_assets = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .{ .custom = "../dist" },
        .install_subdir = "",
    });
    copy_web_assets.step.dependOn(&make_dist.step);
    deploy_step.dependOn(&copy_web_assets.step);

    // --- Run Step: Serve web/ ---
    const run_step = b.step("run", "Build to web/ and serve with Python");
    run_step.dependOn(dev_step);

    const python_cmd = b.addSystemCommand(&[_][]const u8{ "python", "-m", "http.server" });
    python_cmd.setCwd(b.path("web"));
    run_step.dependOn(&python_cmd.step);

    // --- Test Step ---

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const exe_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
