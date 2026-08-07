// The Swift side of Sim.metal, in JavaScript: owns the two sand textures, bakes
// the hardpack once, and drives the substeps.

import { program, floatTexture, framebuffer, bindTexture } from './gl.js';
import { FULLSCREEN_VS, BEDROCK_BAKE_FS, SIM_INIT_FS, SIM_STEP_FS } from './shaders/sim.js';

export const TOOL = { none: 0, dig: 1, pour: 2, pack: 3, wet: 4 };

export class SandSim {
    /// `resolution` is texels along one edge of the 48 m square. The native
    /// build runs 256-640 by quality tier; on a phone in a browser, 256 is the
    /// honest ceiling for a 60 Hz frame with four substeps.
    constructor(gl, floatRenderable, resolution = 256) {
        this.gl = gl;
        this.resolution = resolution;

        // The hardpack table. 512 texels over +/-40 m is 156 mm — finer than the
        // 187 mm simulation grid, which is the only relationship that matters.
        this.bedrockResolution = 512;

        this.pBake = program(gl, FULLSCREEN_VS, BEDROCK_BAKE_FS, 'bedrock_bake');
        this.pInit = program(gl, FULLSCREEN_VS, SIM_INIT_FS, 'sim_init');
        this.pStep = program(gl, FULLSCREEN_VS, SIM_STEP_FS, 'sim_step');

        this.bedrock = floatTexture(gl, this.bedrockResolution, this.bedrockResolution, floatRenderable);
        this.bedrockFBO = framebuffer(gl, this.bedrock);

        this.front = floatTexture(gl, resolution, resolution, floatRenderable);
        this.back = floatTexture(gl, resolution, resolution, floatRenderable);
        this.frontFBO = framebuffer(gl, this.front);
        this.backFBO = framebuffer(gl, this.back);

        this.brush = { x: 0, z: 0, radius: 2.2, strength: 0, tool: TOOL.none };

        this.bakeBedrock();
    }

    /// The hardpack never changes, so it is derived once and read back for the
    /// rest of the session. Baked here rather than on the first reset because
    /// `sim_init` reads it, and so does every pass in every frame — a table that
    /// only becomes correct after a beach has been laid down is a trap.
    bakeBedrock() {
        const gl = this.gl;
        gl.bindFramebuffer(gl.FRAMEBUFFER, this.bedrockFBO);
        gl.viewport(0, 0, this.bedrockResolution, this.bedrockResolution);
        gl.useProgram(this.pBake.handle);
        gl.uniform1f(this.pBake.uniforms.uResolution, this.bedrockResolution);
        gl.drawArrays(gl.TRIANGLES, 0, 3);

        // Keep a copy on the CPU while the framebuffer is still bound.
        //
        // This is what the picking ray marches against, and reading the baked
        // table back is why the CPU never has to reimplement the noise — a
        // second copy of `bedrock()` in JavaScript would drift from the GLSL one
        // the first time either was touched, and the symptom would be sand
        // appearing a metre from your finger.
        const N = this.bedrockResolution;
        this.heightMirror = null;
        try {
            const buf = new Float32Array(N * N * 4);
            gl.readPixels(0, 0, N, N, gl.RGBA, gl.FLOAT, buf);
            if (gl.getError() === gl.NO_ERROR) { this.heightMirror = buf; }
        } catch (e) {
            // Half-float fallback devices may refuse a FLOAT read. Picking drops
            // to a fixed plane, which is worse but not broken.
        }

        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }

    /// Ground height at a world position, from the CPU mirror.
    ///
    /// This is the *pristine* shore — hardpack plus the bed the tide left — not
    /// the live field, so a tower you built yourself is not in it. That is the
    /// honest limit of picking without a readback per frame, and it costs
    /// nothing where the game is actually played: the working pad is flat.
    groundAt(x, z) {
        const mirror = this.heightMirror;
        if (!mirror) { return 1.0; }

        const N = this.bedrockResolution;
        const E = 40.0;                       // must match SK BEDROCK_EXTENT
        const gx = ((x + E) / (2 * E)) * (N - 1);
        const gz = ((z + E) / (2 * E)) * (N - 1);
        if (!(gx >= 0 && gz >= 0 && gx <= N - 1 && gz <= N - 1)) { return 0.0; }

        const i0 = Math.floor(gx), j0 = Math.floor(gz);
        const i1 = Math.min(i0 + 1, N - 1), j1 = Math.min(j0 + 1, N - 1);
        const fx = gx - i0, fz = gz - j0;

        // .r is the hardpack and .g the loose bed; their sum is the surface.
        const at = (i, j) => {
            const k = (j * N + i) * 4;
            return mirror[k] + mirror[k + 1];
        };

        return (at(i0, j0) * (1 - fx) + at(i1, j0) * fx) * (1 - fz)
             + (at(i0, j1) * (1 - fx) + at(i1, j1) * fx) * fz;
    }

    /// Lay down a fresh beach.
    reset(seaBase = -0.35) {
        const gl = this.gl;
        gl.bindFramebuffer(gl.FRAMEBUFFER, this.frontFBO);
        gl.viewport(0, 0, this.resolution, this.resolution);
        gl.useProgram(this.pInit.handle);
        gl.uniform1f(this.pInit.uniforms.uResolution, this.resolution);
        gl.uniform1f(this.pInit.uniforms.uSeaBase, seaBase);
        bindTexture(gl, this.pInit, 'uBedrock', 0, this.bedrock);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }

    /// Advance the solver. `dt` is the whole frame's worth of time, divided
    /// across the substeps internally.
    step(dt, substeps, env) {
        const gl = this.gl;

        // Cap the frame's simulated time. A stall — a phone call, the app coming
        // back from the background — must not deliver half a second of avalanche
        // in one go and knock the castle over while nobody was looking.
        const clamped = Math.min(dt, 1 / 20);
        const sub = clamped / substeps;

        gl.viewport(0, 0, this.resolution, this.resolution);
        gl.useProgram(this.pStep.handle);

        const u = this.pStep.uniforms;
        gl.uniform1f(u.uResolution, this.resolution);
        gl.uniform1f(u.uDt, sub);
        gl.uniform1f(u.uSeaBase, env.seaBase);
        gl.uniform1f(u.uWaveAmp, env.waveAmplitude);
        gl.uniform1f(u.uErosion, env.erosion);
        gl.uniform4f(u.uBrush, this.brush.x, this.brush.z, this.brush.radius, this.brush.strength);
        gl.uniform1i(u.uTool, this.brush.tool);

        for (let i = 0; i < substeps; i++) {
            gl.uniform1f(u.uTime, env.time + sub * i);

            gl.bindFramebuffer(gl.FRAMEBUFFER, this.backFBO);
            bindTexture(gl, this.pStep, 'uField', 0, this.front);
            bindTexture(gl, this.pStep, 'uBedrock', 1, this.bedrock);
            gl.drawArrays(gl.TRIANGLES, 0, 3);

            // Ping-pong. The just-written texture becomes the one everybody
            // reads, so the renderer never sees a half-solved field.
            [this.front, this.back] = [this.back, this.front];
            [this.frontFBO, this.backFBO] = [this.backFBO, this.frontFBO];
        }

        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }

    setBrush(worldX, worldZ, radius, strength, tool) {
        this.brush.x = worldX;
        this.brush.z = worldZ;
        this.brush.radius = radius;
        this.brush.strength = strength;
        this.brush.tool = tool;
    }

    clearBrush() {
        this.brush.strength = 0;
        this.brush.tool = TOOL.none;
    }
}
