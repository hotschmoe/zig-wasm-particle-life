// Thin host for the Zig module: owns the WebGPU objects behind integer handles
// and forwards the calls declared in src/gpu.zig. All simulation logic is in Zig.

import { UI } from './ui.js';

const BINDING_LAYOUTS = [
    { buffer: { type: 'uniform' } },
    { buffer: { type: 'storage' } },
    { buffer: { type: 'read-only-storage' } },
    { buffer: { type: 'uniform', hasDynamicOffset: true } },
    { texture: { sampleType: 'float', viewDimension: '2d' } },
];

const HDR_FORMAT = 'rgba16float';
const ADDITIVE_BLEND = {
    color: { srcFactor: 'src-alpha', dstFactor: 'one', operation: 'add' },
    alpha: { srcFactor: 'one', dstFactor: 'one', operation: 'add' },
};

const decoder = new TextDecoder();
const handles = new Map();
let nextHandle = 1;
let wasm = null;
let device = null;
let context = null;
let canvasFormat = null;

const track = (object) => {
    const id = nextHandle++;
    handles.set(id, object);
    return id;
};
const get = (id) => handles.get(id);
const bytes = (ptr, len) => new Uint8Array(wasm.exports.memory.buffer, ptr, len);
const words = (ptr, len) => new Uint32Array(wasm.exports.memory.buffer, ptr, len);
const text = (ptr, len) => decoder.decode(bytes(ptr, len));

const colorTarget = (target) =>
    target === 0 ? { format: HDR_FORMAT, blend: ADDITIVE_BLEND } : { format: canvasFormat };

const pipelineLayout = (ptr, len) =>
    device.createPipelineLayout({
        bindGroupLayouts: Array.from(words(ptr, len), get),
    });

const beginPass = (encoderId, view, r, g, b, a) =>
    track(get(encoderId).beginRenderPass({
        colorAttachments: [{
            view,
            clearValue: { r, g, b, a },
            loadOp: 'clear',
            storeOp: 'store',
        }],
    }));

// Each function maps 1:1 to an `extern "gpu"` declaration in src/gpu.zig.
// Creation functions return 0 on failure.
const gpu = {
    createBuffer: (size, usage) => track(device.createBuffer({ size, usage })),

    writeBuffer: (buffer, ptr, len) => device.queue.writeBuffer(get(buffer), 0, bytes(ptr, len)),

    createShaderModule: (ptr, len) => track(device.createShaderModule({ code: text(ptr, len) })),

    createBindGroupLayout: (visibility, kindsPtr, len) =>
        track(device.createBindGroupLayout({
            entries: Array.from(words(kindsPtr, len), (kind, binding) => ({
                binding,
                visibility,
                ...BINDING_LAYOUTS[kind],
            })),
        })),

    // Entries are (resource handle, byte size) pairs; size 0 binds the whole buffer.
    createBindGroup: (layout, entriesPtr, len) => {
        const pairs = words(entriesPtr, len * 2);
        const entries = [];
        for (let binding = 0; binding < len; binding++) {
            const resource = get(pairs[binding * 2]);
            const size = pairs[binding * 2 + 1];
            entries.push({
                binding,
                resource: resource instanceof GPUBuffer
                    ? (size ? { buffer: resource, size } : { buffer: resource })
                    : resource,
            });
        }
        return track(device.createBindGroup({ layout: get(layout), entries }));
    },

    createComputePipeline: (module, entryPtr, entryLen, layoutsPtr, layoutsLen) =>
        track(device.createComputePipeline({
            layout: pipelineLayout(layoutsPtr, layoutsLen),
            compute: { module: get(module), entryPoint: text(entryPtr, entryLen) },
        })),

    createRenderPipeline: (module, vertexPtr, vertexLen, fragmentPtr, fragmentLen, layoutsPtr, layoutsLen, target) =>
        track(device.createRenderPipeline({
            layout: pipelineLayout(layoutsPtr, layoutsLen),
            vertex: { module: get(module), entryPoint: text(vertexPtr, vertexLen) },
            fragment: {
                module: get(module),
                entryPoint: text(fragmentPtr, fragmentLen),
                targets: [colorTarget(target)],
            },
            primitive: { topology: 'triangle-list' },
        })),

    createRenderTarget: (width, height) =>
        track(device.createTexture({
            size: { width, height },
            format: HDR_FORMAT,
            usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
        })),

    createTextureView: (texture) => track(get(texture).createView()),

    // Buffers and textures are also destroyed explicitly; other objects are left to the GC.
    release: (handle) => {
        get(handle)?.destroy?.();
        handles.delete(handle);
    },

    createEncoder: () => track(device.createCommandEncoder()),

    beginComputePass: (encoder) => track(get(encoder).beginComputePass()),

    beginRenderPass: (encoder, view, r, g, b, a) => beginPass(encoder, get(view), r, g, b, a),

    beginCanvasPass: (encoder, r, g, b, a) =>
        beginPass(encoder, context.getCurrentTexture().createView(), r, g, b, a),

    submit: (encoder) => {
        device.queue.submit([get(encoder).finish()]);
        handles.delete(encoder);
    },

    passSetPipeline: (pass, pipeline) => get(pass).setPipeline(get(pipeline)),
    passSetBindGroup: (pass, index, group) => get(pass).setBindGroup(index, get(group)),
    passSetBindGroupOffset: (pass, index, group, offset) => get(pass).setBindGroup(index, get(group), [offset]),
    dispatch: (pass, workgroups) => get(pass).dispatchWorkgroups(workgroups),
    draw: (pass, vertexCount) => get(pass).draw(vertexCount),
    passEnd: (pass) => {
        get(pass).end();
        handles.delete(pass);
    },
};

const env = {
    log: (ptr, len) => console.log(`[Zig] ${text(ptr, len)}`),
};

const setStatus = (message) => {
    document.getElementById('status').textContent = message;
};

async function loadBlueNoise() {
    try {
        const response = await fetch('blue-noise.png');
        const image = await createImageBitmap(await response.blob(), { colorSpaceConversion: 'none' });
        const texture = device.createTexture({
            format: 'rgba8unorm',
            size: [image.width, image.height],
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
        });
        device.queue.copyExternalImageToTexture({ source: image }, { texture }, [image.width, image.height]);
        return track(texture.createView());
    } catch (error) {
        console.warn('Blue noise unavailable, dithering disabled:', error);
        return 0;
    }
}

async function initWebGPU(canvas) {
    if (!navigator.gpu) throw new Error('WebGPU not supported');
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) throw new Error('No WebGPU adapter available');

    device = await adapter.requestDevice();
    device.addEventListener('uncapturederror', (event) => console.error('WebGPU:', event.error.message));
    canvasFormat = navigator.gpu.getPreferredCanvasFormat();
    context = canvas.getContext('webgpu');
    context.configure({ device, format: canvasFormat, alphaMode: 'opaque' });
}

function resizeCanvas(canvas) {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.max(1, Math.round(canvas.clientWidth * dpr));
    canvas.height = Math.max(1, Math.round(canvas.clientHeight * dpr));
    wasm?.exports.onResize(canvas.width, canvas.height);
}

function startFrameLoop() {
    let last = 0;
    let frames = 0;
    const fps = document.getElementById('fps');
    const frame = (timestamp) => {
        const dt = timestamp - last;
        last = timestamp;
        if (++frames % 60 === 0) fps.textContent = `FPS: ${Math.round(1000 / dt)}`;
        wasm.exports.update(dt / 1000);
        requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
}

async function main() {
    const canvas = document.getElementById('canvas');
    try {
        setStatus('Initializing WebGPU...');
        await initWebGPU(canvas);
        const blueNoise = await loadBlueNoise();

        setStatus('Loading WASM...');
        const response = await fetch(`app.wasm?t=${Date.now()}`);
        if (!response.ok) throw new Error(`Failed to fetch app.wasm: ${response.status}`);
        ({ instance: wasm } = await WebAssembly.instantiate(await response.arrayBuffer(), { env, gpu }));

        wasm.exports.init(Math.floor(Math.random() * 0xFFFFFFFF));
        if (blueNoise) wasm.exports.setBlueNoise(blueNoise);
        resizeCanvas(canvas);
        window.addEventListener('resize', () => resizeCanvas(canvas));

        new UI(wasm.exports, canvas);
        setStatus('Running');
        startFrameLoop();
    } catch (error) {
        console.error('Initialization failed:', error);
        setStatus(`Error: ${error.message}`);
    }
}

main();
