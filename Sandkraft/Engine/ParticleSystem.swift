//
//  ParticleSystem.swift
//  Sandkraft
//
//  A fixed-capacity GPU pool with one rule that makes it more than decoration:
//  a grain that lands puts its sand back into the heightfield.
//
//  Emission requests are queued on the CPU during the frame and dispatched in a
//  single compute encoder just before the update. Batching them matters more
//  than it looks — a stroke of the shovel emits every frame, and one encoder per
//  emitter would put an encoder boundary in the middle of the hot loop.
//

import Foundation
import Metal
import simd

enum ParticleKind: Int32 {
    case grain = 0      // carries sand, deposits on landing
    case spray = 1      // thrown by a breaker, evaporates
    case foam = 2       // sits on the surface briefly
    case dust = 3       // dry sand off a ridge, deposits almost nothing
}

struct EmissionRequest {
    var origin: SIMD3<Float>
    var velocity: SIMD3<Float>
    var count: Int
    var spread: Float
    /// Cubic metres of sand carried by each particle. Zero for spray and foam.
    var volume: Float
    var moisture: Float
    var lifetime: Float
    var kind: ParticleKind
}

final class ParticleSystem {

    private let context: MetalContext
    let capacity: Int

    private let particles: MTLBuffer
    private let cursor: MTLBuffer

    private let pSpawn: MTLComputePipelineState
    private let pUpdate: MTLComputePipelineState

    private var pending: [EmissionRequest] = []
    private var seed: UInt32 = 1

    /// A frame may not queue more than this many emitters. Eight is generous —
    /// the game emits from at most three sources at once — and it caps the worst
    /// case at a knowable number of dispatches.
    private static let maxRequestsPerFrame = 8

    init(context: MetalContext, tier: QualityTier) throws {
        self.context = context
        self.capacity = tier.particleCapacity
        self.simulationResolution = Float(tier.simResolution)

        guard let particles = context.makeBuffer(length: capacity * MemoryLayout<SKParticle>.stride,
                                                 storage: .storageModePrivate, label: "particles.pool"),
              let cursor = context.makeBuffer(length: MemoryLayout<UInt32>.stride,
                                              storage: .storageModePrivate, label: "particles.cursor")
        else { throw MetalSetupError.noDevice }

        self.particles = particles
        self.cursor = cursor
        self.pSpawn = try context.computePipeline("particle_spawn")
        self.pUpdate = try context.computePipeline("particle_update")
    }

    /// Zero the pool. Must be called once before the first update, or every slot
    /// starts life with a garbage lifetime and the beach fills with particles
    /// that were never emitted.
    func clear(in commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "particles.clear"
        blit.fill(buffer: particles, range: 0..<particles.length, value: 0)
        blit.fill(buffer: cursor, range: 0..<cursor.length, value: 0)
        blit.endEncoding()
        pending.removeAll()
    }

    func emit(_ request: EmissionRequest) {
        guard request.count > 0, pending.count < Self.maxRequestsPerFrame else { return }
        pending.append(request)
    }

    // MARK: - Convenience emitters
    //
    // These exist so the game model can say what happened rather than what the
    // particle system should do about it.

    func emitDigSpray(at point: SIMD3<Float>, moisture: Float, volume: Float, toward: SIMD2<Float>) {
        let lateral = SIMD3<Float>(toward.x, 0, toward.y) * 1.4
        emit(EmissionRequest(origin: point + SIMD3(0, 0.05, 0),
                             velocity: SIMD3(0, 2.2, 0) + lateral,
                             count: 14, spread: 0.14,
                             volume: volume / 14, moisture: moisture,
                             lifetime: 0.9, kind: .grain))
    }

    func emitPour(at point: SIMD3<Float>, moisture: Float, volume: Float) {
        emit(EmissionRequest(origin: point + SIMD3(0, 0.45, 0),
                             velocity: SIMD3(0, -0.4, 0),
                             count: 10, spread: 0.10,
                             volume: volume / 10, moisture: moisture,
                             lifetime: 0.7, kind: .grain))
    }

    func emitCollapseDust(at point: SIMD3<Float>, strength: Float) {
        emit(EmissionRequest(origin: point + SIMD3(0, 0.08, 0),
                             velocity: SIMD3(0, 0.5, 0),
                             count: Int(6 + strength * 14), spread: 0.28,
                             volume: 0, moisture: 0,
                             lifetime: 1.4, kind: .dust))
    }

    func emitBreakerSpray(at point: SIMD3<Float>, strength: Float) {
        emit(EmissionRequest(origin: point,
                             velocity: SIMD3(0, 2.4 * strength, -1.8 * strength),
                             count: Int(10 + strength * 26), spread: 0.6,
                             volume: 0, moisture: 1,
                             lifetime: 1.1, kind: .spray))
    }

    // MARK: - Frame

    func update(environment: SimulationEnvironment,
                dt: Float,
                sandTexture: MTLTexture,
                depositBuffer: MTLBuffer,
                in commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            pending.removeAll()
            return
        }
        encoder.label = "particles"

        var u = uniforms(environment, dt: dt)

        for request in pending {
            seed &+= 1
            u.spawnA = SIMD4(request.origin, Float(request.count))
            u.spawnB = SIMD4(request.velocity, request.spread)
            u.seed = seed
            var payload = SIMD4<Float>(request.volume, request.moisture,
                                       request.lifetime, Float(request.kind.rawValue))

            encoder.setComputePipelineState(pSpawn)
            encoder.setBuffer(particles, offset: 0, index: 0)
            encoder.setBuffer(cursor, offset: 0, index: 1)
            encoder.setBytes(&u, length: MemoryLayout<SKParticleUniforms>.stride, index: 2)
            encoder.setBytes(&payload, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            context.dispatch1D(encoder, count: request.count, threadsPerGroup: 64)
        }
        pending.removeAll()

        u.spawnA.w = 0
        encoder.setComputePipelineState(pUpdate)
        encoder.setBuffer(particles, offset: 0, index: 0)
        encoder.setBuffer(depositBuffer, offset: 0, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<SKParticleUniforms>.stride, index: 2)
        encoder.setTexture(sandTexture, index: 0)
        context.dispatch1D(encoder, count: capacity, threadsPerGroup: 64)

        encoder.endEncoding()
    }

    func encodeDraw(encoder: MTLRenderCommandEncoder, frame: inout SKFrameUniforms) {
        encoder.setVertexBuffer(particles, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
        // Every slot is drawn; retired ones collapse to a degenerate triangle in
        // the vertex shader. Compacting the live set would need an indirect draw
        // and a prefix sum to save a vertex-shader invocation that costs four
        // instructions.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: capacity)
    }

    private func uniforms(_ environment: SimulationEnvironment, dt: Float) -> SKParticleUniforms {
        var u = SKParticleUniforms()
        u.domain = SandSimulation.domain
        u.simResolution = simulationResolution
        u.texel = SIMD2(1 / simulationResolution, 1 / simulationResolution)
        u.dt = dt
        u.time = Float(environment.time)
        u.seaBase = Float(environment.seaBase)
        u.waveAmplitude = Float(environment.waveAmplitude)
        u.gravity = 9.81
        u.capacity = UInt32(capacity)
        u.seed = seed
        u.depositFixedPointScale = Float(SandSimulation.depositFixedPointScale)
        return u
    }

    /// The resolution of the field particles land in. Read from the same quality
    /// tier the simulation was built from, so the two cannot disagree about
    /// which texel a grain fell into.
    private let simulationResolution: Float
}
