@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
@group(1) @binding(0) var<uniform> options: SimulationOptions;

@compute @workgroup_size(64)
fn particleAdvance(@builtin(global_invocation_id) id: vec3u) {
    if (id.x >= arrayLength(&particles)) {
        return;
    }

    let width = options.right - options.left;
    let height = options.top - options.bottom;
    var particle = particles[id.x];

    // Apply action force (user interaction)
    var action_r = vec2f(particle.x, particle.y) - vec2f(options.action_x, options.action_y);
    if (options.looping_borders == 1.0) {
        if (abs(action_r.x) >= width * 0.5) {
            action_r.x -= sign(action_r.x) * width;
        }
        if (abs(action_r.y) >= height * 0.5) {
            action_r.y -= sign(action_r.y) * height;
        }
    }
    let action_factor = options.action_force * exp(-dot(action_r, action_r) / (options.action_radius * options.action_radius));
    particle.vx += options.action_vx * action_factor;
    particle.vy += options.action_vy * action_factor;

    // Apply friction
    particle.vx *= options.friction;
    particle.vy *= options.friction;

    // Integrate velocity -> position
    particle.x += particle.vx * options.dt;
    particle.y += particle.vy * options.dt;

    // Handle boundaries
    let looping_borders = options.looping_borders == 1.0;

    if (looping_borders) {
        if (particle.x < options.left) {
            particle.x += width;
        }
        if (particle.x > options.right) {
            particle.x -= width;
        }
        if (particle.y < options.bottom) {
            particle.y += height;
        }
        if (particle.y > options.top) {
            particle.y -= height;
        }
    } else {
        if (particle.x < options.left) {
            particle.x = options.left;
            particle.vx *= -1.0;
        }
        if (particle.x > options.right) {
            particle.x = options.right;
            particle.vx *= -1.0;
        }
        if (particle.y < options.bottom) {
            particle.y = options.bottom;
            particle.vy *= -1.0;
        }
        if (particle.y > options.top) {
            particle.y = options.top;
            particle.vy *= -1.0;
        }
    }

    particles[id.x] = particle;
}
