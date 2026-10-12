// DOM controls and input events. Every handler forwards straight to a Zig export.

const $ = (id) => document.getElementById(id);

export class UI {
    constructor(exports, canvas) {
        this.exports = exports;
        this.canvas = canvas;
        this.paused = false;

        this.bindPointer();
        this.bindControls();
        this.bindKeyboard();
    }

    // Pointer position in canvas pixels.
    pointerPosition(clientX, clientY) {
        const rect = this.canvas.getBoundingClientRect();
        const dpr = window.devicePixelRatio || 1;
        return [(clientX - rect.left) * dpr, (clientY - rect.top) * dpr];
    }

    bindPointer() {
        const { exports, canvas } = this;

        canvas.addEventListener('mousemove', (e) => {
            exports.setMousePosition(...this.pointerPosition(e.clientX, e.clientY));
            // buttons is a bitmask: 2 = right, 4 = middle.
            if (e.buttons & (2 | 4)) exports.setPan(e.movementX, e.movementY);
        });

        canvas.addEventListener('mousedown', (e) => {
            if (e.button === 0) exports.setMouseDown(true);
            else if (e.button === 2) exports.setMouseRightDown(true);
        });

        canvas.addEventListener('mouseup', (e) => {
            if (e.button === 0) exports.setMouseDown(false);
            else if (e.button === 2) exports.setMouseRightDown(false);
        });

        canvas.addEventListener('contextmenu', (e) => e.preventDefault());

        canvas.addEventListener('wheel', (e) => {
            e.preventDefault();
            exports.setZoom(e.deltaY);
        }, { passive: false });

        const touch = (e, down) => {
            e.preventDefault();
            if (e.touches.length > 0) {
                exports.setMousePosition(...this.pointerPosition(e.touches[0].clientX, e.touches[0].clientY));
            }
            if (down !== null) exports.setMouseDown(down);
        };
        canvas.addEventListener('touchstart', (e) => touch(e, true), { passive: false });
        canvas.addEventListener('touchmove', (e) => touch(e, null), { passive: false });
        canvas.addEventListener('touchend', (e) => {
            e.preventDefault();
            exports.setMouseDown(false);
        });
    }

    // Wires a range input to a label and a Zig setter, then applies its initial value.
    bindSlider(id, labelId, update) {
        const slider = $(id);
        const label = $(labelId);
        const apply = () => {
            label.innerText = update(parseFloat(slider.value));
        };
        slider.addEventListener('input', apply);
        apply();
    }

    bindCheckbox(id, setter) {
        const box = $(id);
        const apply = () => setter(box.checked);
        box.addEventListener('change', apply);
        apply();
    }

    bindControls() {
        const { exports } = this;

        this.bindSlider('particleCountSlider', 'particleCountText', (v) => {
            const count = Math.round(2 ** v);
            exports.setParticleCount(count);
            return `${count} particles`;
        });
        this.bindSlider('speciesCountSlider', 'speciesCountText', (v) => {
            exports.setSpeciesCount(v);
            return `${v} particle types`;
        });

        // Both dimensions go through one setter so a single frame rebuilds once.
        const worldSize = () => [$('simulationWidthSlider').value * 64, $('simulationHeightSlider').value * 64];
        this.bindSlider('simulationWidthSlider', 'simulationWidthText', (v) => {
            exports.setSimulationSize(...worldSize());
            return `Width: ${v * 64}`;
        });
        this.bindSlider('simulationHeightSlider', 'simulationHeightText', (v) => {
            exports.setSimulationSize(...worldSize());
            return `Height: ${v * 64}`;
        });

        this.bindSlider('frictionSlider', 'frictionText', (v) => {
            exports.setFriction(v);
            return `Friction: ${v}`;
        });
        this.bindSlider('centralForceSlider', 'centralForceText', (v) => {
            exports.setCentralForce(v / 10);
            return `Central force: ${(v / 10).toFixed(1)}`;
        });

        this.bindCheckbox('loopingBorders', exports.setLoopingBorders);
        this.bindCheckbox('symmetricForces', exports.setSymmetricForces);

        $('toggleSettingsButton').addEventListener('click', () => this.toggleSettings());
        $('pauseButton').addEventListener('click', () => this.togglePause());
        $('centerViewButton').addEventListener('click', () => exports.centerView());
        $('restartButton').addEventListener('click', () => exports.restart());
        $('randomizeButton').addEventListener('click', () => exports.randomize());
        $('copyUrlButton').addEventListener('click', () => alert('URL copying not yet implemented'));
        $('fullscreenButton').addEventListener('click', () => this.toggleFullscreen());
    }

    bindKeyboard() {
        const shortcuts = {
            ' ': () => this.togglePause(),
            c: () => this.exports.centerView(),
            s: () => this.toggleSettings(),
        };
        window.addEventListener('keydown', (e) => {
            const action = shortcuts[e.key];
            if (action) {
                action();
                e.preventDefault();
            }
        });
    }

    togglePause() {
        this.paused = !this.paused;
        this.exports.setPaused(this.paused);
        $('pauseButton').innerText = this.paused ? 'Continue' : 'Pause';
    }

    toggleSettings() {
        const panel = $('toolsPanel');
        const hidden = panel.style.opacity === '0' || panel.style.visibility === 'hidden';
        panel.style.opacity = hidden ? '1' : '0';
        panel.style.visibility = hidden ? 'visible' : 'hidden';
    }

    toggleFullscreen() {
        const button = $('fullscreenButton');
        if (document.fullscreenElement) {
            document.exitFullscreen();
            button.innerText = 'Fullscreen';
        } else {
            document.body.requestFullscreen().catch((error) => {
                console.error(`Error attempting to enable fullscreen: ${error.message}`);
            });
            button.innerText = 'Exit Fullscreen';
        }
    }
}
