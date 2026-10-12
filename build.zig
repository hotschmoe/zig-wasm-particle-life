const std = @import("std");

pub fn build(b: *std.Build) void {
    // Size is what ships, so every step builds ReleaseSmall unless told otherwise.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default: small)") orelse .small;

    const options = b.addOptions();
    options.addOption(i64, "build_timestamp", std.Io.Timestamp.now(b.graph.io, .real).toSeconds());

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
            .strip = true,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.entry = .disabled;
    exe.export_memory = true;
    exe.rdynamic = true;
    // Particle state lives on the GPU, so the linear memory only holds statics and a small stack.
    exe.stack_size = 64 * 1024;

    b.installArtifact(exe);
    const wasm = exe.getEmittedBin();

    // Static site: everything under web/ plus the freshly built module.
    const site = b.addWriteFiles();
    _ = site.addCopyDirectory(b.path("web"), ".", .{ .exclude_extensions = &.{".wasm"} });
    _ = site.addCopyFile(wasm, "app.wasm");

    const deploy = b.step("deploy", "Assemble the static site in dist/");
    // The pipeline publishes dist/ at the repository root, so step out of the install prefix.
    deploy.dependOn(&b.addInstallDirectory(.{
        .source_dir = site.getDirectory(),
        .install_dir = .{ .custom = "../dist" },
        .install_subdir = "",
    }).step);

    const dev = b.step("dev", "Write app.wasm next to the web sources in web/");
    const update_web = b.addUpdateSourceFiles();
    update_web.addCopyFileToSource(wasm, "web/app.wasm");
    dev.dependOn(&update_web.step);

    const run = b.step("run", "Build, then serve web/ on http://localhost:8000");
    const serve = b.addSystemCommand(&.{ if (@import("builtin").os.tag == .windows) "python" else "python3", "-m", "http.server" });
    serve.setCwd(b.path("web"));
    serve.step.dependOn(dev);
    run.dependOn(&serve.step);
}
