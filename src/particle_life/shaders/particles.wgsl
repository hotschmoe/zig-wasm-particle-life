// Particle structure
struct Particle {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    species: f32,
}

// Species color
struct Species {
    color: vec4f,
}

// Camera parameters
struct Camera {
    center: vec2f,
    extent: vec2f,
    pixels_per_unit: f32,
}

// Bindings
@group(0) @binding(0) var<storage, read> particles: array<Particle>;
@group(0) @binding(1) var<storage, read> species: array<Species>;
@group(1) @binding(0) var<uniform> camera: Camera;

// Vertex output for circle rendering
struct CircleVertexOut {
    @builtin(position) position: vec4f,
    @location(0) offset: vec2f,
    @location(1) color: vec4f,
}

// Quad offsets (2 triangles = 6 vertices)
const offsets = array<vec2f, 6>(
    vec2f(-1.0, -1.0),
    vec2f( 1.0, -1.0),
    vec2f(-1.0,  1.0),
    vec2f(-1.0,  1.0),
    vec2f( 1.0, -1.0),
    vec2f( 1.0,  1.0),
);


@vertex
fn vertexGlow(@builtin(vertex_index) id: u32) -> CircleVertexOut {
    let particle = particles[id / 6u];
    let offset = offsets[id % 6u];
    let position = vec2f(particle.x, particle.y) + 12.0 * offset;
    return CircleVertexOut(
        vec4f((position - camera.center) / camera.extent, 0.0, 1.0),
        offset,
        species[u32(particle.species)].color
    );
}

@fragment
fn fragmentGlow(in: CircleVertexOut) -> @location(0) vec4f {
    let l = length(in.offset);
    let alpha = exp(-6.0 * l * l) / 64.0;
    return in.color * vec4f(1.0, 1.0, 1.0, alpha);
}


@vertex
fn vertexCircle(@builtin(vertex_index) id: u32) -> CircleVertexOut {
    let particle = particles[id / 6u];
    let offset = offsets[id % 6u] * 1.5;
    let position = vec2f(particle.x, particle.y) + offset;
    return CircleVertexOut(
        vec4f((position - camera.center) / camera.extent, 0.0, 1.0),
        offset,
        species[u32(particle.species)].color
    );
}

@fragment
fn fragmentCircle(in: CircleVertexOut) -> @location(0) vec4f {
    let alpha = clamp(camera.pixels_per_unit - length(in.offset) * camera.pixels_per_unit + 0.5, 0.0, 1.0);
    return in.color * vec4f(1.0, 1.0, 1.0, alpha);
}


@vertex
fn vertexPoint(@builtin(vertex_index) id: u32) -> CircleVertexOut {
    let particle = particles[id / 6u];
    let offset = 2.0 * offsets[id % 6u] / camera.pixels_per_unit;
    let position = vec2f(particle.x, particle.y) + offset;
    return CircleVertexOut(
        vec4f((position - camera.center) / camera.extent, 0.0, 1.0),
        offset,
        species[u32(particle.species)].color
    );
}

const PI = 3.1415926535;

@fragment
fn fragmentPoint(in: CircleVertexOut) -> @location(0) vec4f {
    let d = max(vec2(0.0), min(in.offset * camera.pixels_per_unit + 0.5, vec2(camera.pixels_per_unit)) - max(in.offset * camera.pixels_per_unit - 0.5, -vec2(camera.pixels_per_unit)));
    let alpha = (PI / 4.0) * d.x * d.y;
    return vec4f(in.color.rgb, in.color.a * alpha);
}
