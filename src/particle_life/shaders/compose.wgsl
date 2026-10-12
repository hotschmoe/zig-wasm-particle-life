@group(0) @binding(0) var hdr_texture: texture_2d<f32>;
@group(0) @binding(1) var blue_noise_texture: texture_2d<f32>;

const vertices = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f( 3.0, -1.0),
    vec2f(-1.0,  3.0),
);

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) texcoord: vec2f,
}

@vertex
fn vertexMain(@builtin(vertex_index) id: u32) -> VertexOut {
    let vertex = vertices[id];
    return VertexOut(
        vec4f(vertex, 0.0, 1.0),
        vertex * 0.5 + vec2f(0.5)
    );
}

fn acesTonemap(x: vec3f) -> vec3f {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x*(a*x+b))/(x*(c*x+d)+e), vec3f(0.0), vec3f(1.0));
}

fn dither(x: vec3f, n: f32) -> vec3f {
    let c = x * 255.0;
    let c0 = floor(c);
    let c1 = c0 + vec3f(1.0);
    let dc = c - c0;

    var r = c0;
    if (dc.r > n) { r.r = c1.r; }
    if (dc.g > n) { r.g = c1.g; }
    if (dc.b > n) { r.b = c1.b; }

    return r / 255.0;
}

@fragment
fn fragmentMain(in: VertexOut) -> @location(0) vec4f {
    var sample = textureLoad(hdr_texture, vec2i(in.position.xy), 0);
    let noise = textureLoad(blue_noise_texture, vec2u(in.position.xy) % textureDimensions(blue_noise_texture), 0).r;

    var color = sample.rgb;
    color = acesTonemap(color);
    color = pow(color, vec3f(1.0 / 2.2));
    color = dither(color, noise);

    return vec4f(color, 1.0);
}
