//! WGSL sources, embedded at compile time. The structs in `shaders/common.wgsl`
//! mirror `types.zig`.

const common = @embedFile("shaders/common.wgsl") ++ "\n";

/// Entry points: `clearBinSize`, `fillBinSize`.
pub const binning = common ++ @embedFile("shaders/binning.wgsl");
/// Entry point: `prefixSumStep`.
pub const prefix_sum = @embedFile("shaders/prefix_sum.wgsl");
/// Entry points: `clearBinSize`, `sortParticles`.
pub const sort = common ++ @embedFile("shaders/sort.wgsl");
/// Entry point: `computeForces`.
pub const forces = common ++ @embedFile("shaders/forces.wgsl");
/// Entry point: `particleAdvance`.
pub const advance = common ++ @embedFile("shaders/advance.wgsl");
/// Entry point: `initParticles`.
pub const init = common ++ @embedFile("shaders/init.wgsl");
/// Entry points: `vertexGlow`/`fragmentGlow`, `vertexCircle`/`fragmentCircle`,
/// `vertexPoint`/`fragmentPoint`.
pub const particles = @embedFile("shaders/particles.wgsl");
/// Entry points: `vertexMain`, `fragmentMain`.
pub const compose = @embedFile("shaders/compose.wgsl");
