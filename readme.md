# Zig WASM WebGPU Particle Life

A freestanding Zig -> `wasm32` WebGPU recreation of Nikita Lisitsa's Particle Life simulation, driven through a thin JavaScript FFI layer.

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org/)
[![WebGPU](https://img.shields.io/badge/WebGPU-Enabled-blue.svg)](https://www.w3.org/TR/webgpu/)

## Objectives

**Primary Goal**: Verify that freestanding Zig WASM can successfully drive WebGPU APIs through minimal JavaScript FFI bindings. The Particle Life simulation serves as validation that the FFI layer handles compute pipelines, render pipelines, buffer management, and multi-pass orchestration correctly.

**Secondary Goal**: Establish a reusable pattern for building WebGPU applications in Zig. Once validated, this FFI layer becomes a foundation for other GPU-accelerated web applications without JavaScript overhead.

## Implementation

The project recreates Nikita Lisitsa's Particle Life 2D simulation ([original demo](https://lisyarus.github.io/webgpu/particle-life.html), [blog post](https://lisyarus.github.io/blog/posts/particle-life-simulation-in-browser-using-webgpu.html)). The reference implementation in `docs/nikita_demo` is a 2548-line HTML file containing JavaScript, WebGPU code, and WGSL shaders that runs 65k+ particles at 60fps.

This simulation exercises the complete WebGPU API surface:
- Compute pipelines: particle forces, spatial binning, sorting, state advancement
- Render pipelines: particle visualization with HDR tone mapping and glow effects
- Buffer operations: storage buffers, uniform buffers, atomic operations
- Pipeline coordination: multiple dependent compute passes per frame
- Performance requirements: real-time execution with 65k+ particles

## Architecture

Target: `wasm32-freestanding`

Constraints:
- No WASI - WebGPU provides necessary APIs
- No Emscripten - avoid JavaScript runtime bloat
- No WASM frameworks - direct FFI control
- Minimal JavaScript - `web/main.js` only owns WebGPU objects behind integer handles and forwards calls; `web/ui.js` forwards DOM events

Rationale: Zig's freestanding target provides low-level control, predictable performance, and zero runtime overhead. WASM delivers near-native execution speed across browsers. WebGPU offers modern GPU compute with broad device support. The architecture keeps all simulation logic in Zig while JavaScript serves only as a thin FFI layer to WebGPU browser APIs.

Performance target: match or exceed the reference JavaScript implementation.

### Source layout

| Path | Role |
| --- | --- |
| `src/main.zig` | The exported ABI (`init`, `update`, input and control setters) and application state |
| `src/gpu.zig` | Typed WebGPU handles and the `extern "gpu"` imports implemented by `web/main.js` |
| `src/input.zig` | Pointer and settings state pushed from the page |
| `src/particle_life/physics.zig` | Compute pipelines: binning, prefix sum, sort, forces, integration |
| `src/particle_life/renderer.zig` | HDR particle pass and tone-mapped compose pass |
| `src/particle_life/simulation.zig` | Ties the two together with the camera and mouse interaction |
| `src/particle_life/system.zig` | Random species colors and force matrices |
| `src/particle_life/shaders/` | WGSL sources, embedded with `@embedFile` |

Everything that runs per frame on the CPU is a few dozen FFI calls recording GPU work; particle state never leaves the GPU.

## Building

Requires Zig 0.17.0.

```
zig build deploy   # static site in dist/ (app.wasm + web/ assets), relative URLs only
zig build dev      # write app.wasm into web/ for local serving
zig build run      # dev, then serve web/ with python on http://localhost:8000
```

All steps build `ReleaseSmall` by default; pass `-Doptimize=debug|safe|fast|small` to override.
