// UI and Input Handling for Zig Particle Life

export class UI {
    constructor(wasmInstance, canvas) {
        this.wasm = wasmInstance;
        this.canvas = canvas;
        this.exports = wasmInstance.exports;
        this.paused = false;

        this.setupInputListeners();
        this.setupUIControls();
        this.setupKeyboardShortcuts();
        this.syncInitialControls();
    }

    setupInputListeners() {
        const canvas = this.canvas;

        // Mouse Move
        canvas.addEventListener('mousemove', (e) => {
            const rect = canvas.getBoundingClientRect();
            const dpr = window.devicePixelRatio || 1;
            const x = (e.clientX - rect.left) * dpr;
            const y = (e.clientY - rect.top) * dpr;

            if (this.exports.setMousePosition) {
                this.exports.setMousePosition(x, y);
            }

            // e.buttons is a bitmask: 1=Left, 2=Right, 4=Middle
            const isRightOrMiddle = (e.buttons & 4) || (e.buttons & 2);
            
            if (isRightOrMiddle) {
                if (e.shiftKey) {
                    // Shift+RMB or Shift+MMB = Rotate camera
                    if (this.exports.setRotation) {
                        this.exports.setRotation(e.movementX, e.movementY);
                    }
                } else {
                    // RMB or MMB without shift = Pan camera
                    if (this.exports.setPan) {
                        this.exports.setPan(e.movementX, e.movementY);
                    }
                }
            }
        });

        // Mouse Down
        canvas.addEventListener('mousedown', (e) => {
            if (e.button === 0) { // Left - attract particles
                if (this.exports.setMouseDown) {
                    this.exports.setMouseDown(true);
                }
            }
            // RMB no longer triggers particle interaction - just camera control
        });

        // Mouse Up
        canvas.addEventListener('mouseup', (e) => {
            if (e.button === 0) { // Left
                if (this.exports.setMouseDown) this.exports.setMouseDown(false);
            }
        });

        // Prevent context menu on right click
        canvas.addEventListener('contextmenu', (e) => e.preventDefault());

        // Wheel (Zoom)
        canvas.addEventListener('wheel', (e) => {
            e.preventDefault();
            if (this.exports.setZoom) {
                this.exports.setZoom(e.deltaY);
            }
        }, { passive: false });

        // Touch support (basic)
        canvas.addEventListener('touchstart', (e) => {
            e.preventDefault();
            if (e.touches.length > 0) {
                const rect = canvas.getBoundingClientRect();
                const dpr = window.devicePixelRatio || 1;
                const x = (e.touches[0].clientX - rect.left) * dpr;
                const y = (e.touches[0].clientY - rect.top) * dpr;
                if (this.exports.setMousePosition) this.exports.setMousePosition(x, y);
                if (this.exports.setMouseDown) this.exports.setMouseDown(true);
            }
        }, { passive: false });

        canvas.addEventListener('touchend', (e) => {
            e.preventDefault();
            if (this.exports.setMouseDown) this.exports.setMouseDown(false);
        });

        canvas.addEventListener('touchmove', (e) => {
            e.preventDefault();
            if (e.touches.length > 0) {
                const rect = canvas.getBoundingClientRect();
                const dpr = window.devicePixelRatio || 1;
                const x = (e.touches[0].clientX - rect.left) * dpr;
                const y = (e.touches[0].clientY - rect.top) * dpr;
                if (this.exports.setMousePosition) this.exports.setMousePosition(x, y);
            }
        }, { passive: false });
    }

    setupUIControls() {
        // Particle Count
        const particleCountSlider = document.getElementById('particleCountSlider');
        const particleCountText = document.getElementById('particleCountText');
        if (particleCountSlider) {
            particleCountSlider.addEventListener('input', (e) => {
                const val = Math.round(Math.pow(2, parseFloat(e.target.value)));
                if (particleCountText) particleCountText.innerText = `${val} particles`;
                if (this.exports.setParticleCount) {
                    this.exports.setParticleCount(val);
                }
            });
        }

        // Species Count
        const speciesCountSlider = document.getElementById('speciesCountSlider');
        const speciesCountText = document.getElementById('speciesCountText');
        if (speciesCountSlider) {
            speciesCountSlider.addEventListener('input', (e) => {
                const val = parseInt(e.target.value);
                if (speciesCountText) speciesCountText.innerText = `${val} particle types`;
                if (this.exports.setSpeciesCount) {
                    this.exports.setSpeciesCount(val);
                }
            });
        }

        // Simulation Width
        const simWidthSlider = document.getElementById('simulationWidthSlider');
        const simWidthText = document.getElementById('simulationWidthText');
        if (simWidthSlider) {
            simWidthSlider.addEventListener('input', (e) => {
                const val = parseInt(e.target.value) * 64;
                if (simWidthText) simWidthText.innerText = `Width: ${val}`;
                this.updateSimulationSize();
            });
        }

        // Simulation Height
        const simHeightSlider = document.getElementById('simulationHeightSlider');
        const simHeightText = document.getElementById('simulationHeightText');
        if (simHeightSlider) {
            simHeightSlider.addEventListener('input', (e) => {
                const val = parseInt(e.target.value) * 64;
                if (simHeightText) simHeightText.innerText = `Height: ${val}`;
                this.updateSimulationSize();
            });
        }

        // Simulation Depth
        const simDepthSlider = document.getElementById('simulationDepthSlider');
        const simDepthText = document.getElementById('simulationDepthText');
        if (simDepthSlider) {
            simDepthSlider.addEventListener('input', (e) => {
                const val = parseInt(e.target.value) * 64;
                if (simDepthText) simDepthText.innerText = `Depth: ${val}`;
                this.updateSimulationSize();
            });
        }

        // Friction
        const frictionSlider = document.getElementById('frictionSlider');
        const frictionText = document.getElementById('frictionText');
        if (frictionSlider) {
            frictionSlider.addEventListener('input', (e) => {
                const val = parseFloat(e.target.value);
                if (frictionText) frictionText.innerText = `Friction: ${val}`;
                if (this.exports.setSimOption) {
                    this.exports.setSimOption(0, val);
                }
            });
        }

        // Central Force
        const centralForceSlider = document.getElementById('centralForceSlider');
        const centralForceText = document.getElementById('centralForceText');
        if (centralForceSlider) {
            centralForceSlider.addEventListener('input', (e) => {
                const val = parseFloat(e.target.value) / 10.0;
                if (centralForceText) centralForceText.innerText = `Central force: ${val.toFixed(1)}`;
                if (this.exports.setSimOption) {
                    this.exports.setSimOption(4, val);
                }
            });
        }

        // Symmetric Forces
        const symmetricForces = document.getElementById('symmetricForces');
        if (symmetricForces) {
            symmetricForces.addEventListener('change', (e) => {
                const val = e.target.checked ? 1.0 : 0.0;
                if (this.exports.setSimOption) {
                    this.exports.setSimOption(5, val);
                }
            });
        }

        // Looping Borders
        const loopingBorders = document.getElementById('loopingBorders');
        if (loopingBorders) {
            loopingBorders.addEventListener('change', (e) => {
                const val = e.target.checked ? 1.0 : 0.0;
                if (this.exports.setSimOption) {
                    this.exports.setSimOption(3, val);
                }
            });
        }

        // Buttons
        document.getElementById('toggleSettingsButton')?.addEventListener('click', () => this.toggleSettings());
        document.getElementById('pauseButton')?.addEventListener('click', () => this.togglePause());
        document.getElementById('centerViewButton')?.addEventListener('click', () => {
            if (this.exports.centerView) this.exports.centerView();
        });
        document.getElementById('restartButton')?.addEventListener('click', () => {
            if (this.exports.restart) this.exports.restart();
        });
        document.getElementById('randomizeButton')?.addEventListener('click', () => {
            if (this.exports.randomize) this.exports.randomize();
        });
        document.getElementById('copyUrlButton')?.addEventListener('click', () => this.copyUrl());
        document.getElementById('fullscreenButton')?.addEventListener('click', () => this.toggleFullscreen());
    }

    syncInitialControls() {
        const fireInput = (id, type = 'input') => {
            const el = document.getElementById(id);
            if (el) {
                el.dispatchEvent(new Event(type));
            }
        };

        fireInput('particleCountSlider');
        fireInput('speciesCountSlider');
        fireInput('simulationDepthSlider');
        this.updateSimulationSize();
        fireInput('frictionSlider');
        fireInput('centralForceSlider');
        fireInput('loopingBorders', 'change');
        fireInput('symmetricForces', 'change');
    }

    setupKeyboardShortcuts() {
        window.addEventListener('keydown', (e) => {
            if (e.key === ' ') {
                this.togglePause();
                e.preventDefault();
            }
            if (e.key === 'c') {
                if (this.exports.centerView) this.exports.centerView();
                e.preventDefault();
            }
            if (e.key === 's') {
                this.toggleSettings();
                e.preventDefault();
            }
        });
    }

    updateSimulationSize() {
        const w = Number(document.getElementById('simulationWidthSlider')?.value ?? 16) * 64;
        const h = Number(document.getElementById('simulationHeightSlider')?.value ?? 16) * 64;
        const d = Number(document.getElementById('simulationDepthSlider')?.value ?? 16) * 64;
        if (this.exports.setSimulationSize) {
            this.exports.setSimulationSize(w, h, d);
        }
    }

    togglePause() {
        this.paused = !this.paused;
        const btn = document.getElementById('pauseButton');
        if (btn) btn.innerText = this.paused ? "Continue" : "Pause";
    }

    toggleSettings() {
        const panel = document.getElementById('toolsPanel');
        if (panel) {
            const isHidden = panel.style.opacity === '0' || panel.style.visibility === 'hidden';
            panel.style.opacity = isHidden ? '1' : '0';
            panel.style.visibility = isHidden ? 'visible' : 'hidden';
        }
    }

    toggleFullscreen() {
        if (!document.fullscreenElement) {
            document.body.requestFullscreen().catch(err => {
                console.error(`Error attempting to enable fullscreen: ${err.message}`);
            });
            document.getElementById('fullscreenButton').innerText = "Exit Fullscreen";
        } else {
            document.exitFullscreen();
            document.getElementById('fullscreenButton').innerText = "Fullscreen";
        }
    }

    copyUrl() {
        // TODO: Implement URL state serialization
        alert("URL copying not yet implemented");
    }

    isPaused() {
        return this.paused;
    }
}
