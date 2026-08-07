// Bootstrap and the frame loop.

import { getContext, GLError } from './gl.js';
import { SandSim, TOOL } from './sim.js';
import { Renderer } from './renderer.js';
import { Camera } from './camera.js';
import { Input } from './input.js';

// Two tiers, chosen from the device rather than offered as a setting. A phone
// that cannot hold the high one should not be asked to decide that about itself.
const TIERS = {
    phone:   { sim: 192, terrainGrid: 176, skirtGrid: 96,  waterGrid: 112, substeps: 3, maxDPR: 2.0 },
    desktop: { sim: 256, terrainGrid: 288, skirtGrid: 144, waterGrid: 176, substeps: 4, maxDPR: 2.0 },
};

const canvas = document.getElementById('scene');
const ui = document.getElementById('ui');
const fatal = document.getElementById('fatal');

function die(message) {
    fatal.textContent = message;
    fatal.hidden = false;
    ui.hidden = true;
    canvas.hidden = true;
}

let gl, floatRenderable;
try {
    ({ gl, floatRenderable } = getContext(canvas));
} catch (err) {
    die(err instanceof GLError ? err.message : String(err));
    throw err;
}

const coarse = window.matchMedia('(pointer: coarse)').matches;
const tier = coarse ? TIERS.phone : TIERS.desktop;

const sim = new SandSim(gl, floatRenderable, tier.sim);
const renderer = new Renderer(gl, tier);
const camera = new Camera();

sim.reset();

const env = {
    time: 0,
    seaBase: -0.35,
    waveAmplitude: 0.85,
    erosion: 1.0,
    sunDir: normalize3([0.42, 0.72, 0.35]),
};

const state = {
    tool: TOOL.dig,
    radius: 2.2,
    working: false,
    cursor: null,
    tide: true,
};

// -------------------------------------------------------------------- canvas

function resize() {
    // Clamp the pixel ratio. A 3x iPhone display asks for nine times the
    // fragments of a 1x one, and the ink outline is the same width either way —
    // so past 2x you are paying for pixels nobody can see.
    const dpr = Math.min(window.devicePixelRatio || 1, tier.maxDPR);
    const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
    const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
    if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
    }
    renderer.resize(w, h);
}

window.addEventListener('resize', resize);
window.addEventListener('orientationchange', () => setTimeout(resize, 120));
resize();

// --------------------------------------------------------------------- input

const groundAt = (x, z) => sim.groundAt(x, z);

function applyWork(nx, ny) {
    const p = camera.pickGround(nx, ny, groundAt);
    if (!p) { return; }
    state.cursor = p;
    state.working = true;
    sim.setBrush(p[0], p[1], state.radius, 1.0, state.tool);
}

new Input(canvas, camera, {
    onWork: applyWork,
    onHover: (nx, ny) => { state.cursor = camera.pickGround(nx, ny, groundAt); },
    onStopWork: () => { state.working = false; sim.clearBrush(); },
});

// ------------------------------------------------------------------------ UI

for (const button of document.querySelectorAll('[data-tool]')) {
    button.addEventListener('click', () => {
        state.tool = TOOL[button.dataset.tool];
        for (const b of document.querySelectorAll('[data-tool]')) {
            b.classList.toggle('on', b === button);
        }
    });
}

document.getElementById('size').addEventListener('input', (e) => {
    state.radius = parseFloat(e.target.value);
});

const tideButton = document.getElementById('tide');
tideButton.addEventListener('click', () => {
    state.tide = !state.tide;
    env.erosion = state.tide ? 1.0 : 0.0;
    tideButton.classList.toggle('on', state.tide);
    tideButton.querySelector('.label').textContent = state.tide ? 'Tide' : 'Calm';
});

document.getElementById('reset').addEventListener('click', () => {
    sim.reset(env.seaBase);
});

// ------------------------------------------------------------------- the loop

let last = performance.now();
let accumulator = 0;

function frame(now) {
    const dt = Math.min((now - last) / 1000, 0.1);
    last = now;

    env.time += dt;

    // The brush is a rate, not an impulse, so a finger held still keeps digging.
    // Released, it stops on the next step rather than the next frame — which is
    // what stops a fast flick leaving a comet trail of holes.
    if (!state.working) { sim.clearBrush(); }

    sim.step(dt, tier.substeps, env);

    camera.update(canvas.width / canvas.height);
    renderer.draw(sim, camera, env);

    requestAnimationFrame(frame);
}

requestAnimationFrame(frame);

// The page starts hidden so a failed context does not flash a dead UI first.
ui.hidden = false;

function normalize3(v) {
    const l = Math.hypot(v[0], v[1], v[2]) || 1;
    return new Float32Array([v[0] / l, v[1] / l, v[2] / l]);
}
