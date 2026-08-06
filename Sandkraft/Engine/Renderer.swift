//
//  Renderer.swift
//  Sandkraft
//
//  One frame, start to finish.
//
//    bake sky (on demand)  →  shadow  →  opaque  →  copy  →  water
//                          →  particles  →  bloom  →  composite
//
//  The two things worth knowing before editing:
//
//    · The sky LUT is baked only when the sun has actually moved. At "Held" day
//      speed — which is how most sandbox sessions are played — it is baked once
//      and never again, and the atmosphere becomes free.
//
//    · Water composites by hand against a copy of the opaque buffer rather than
//      by blending. That is what pays for refraction and for a soft waterline,
//      and it is why there is a full-resolution copy in the middle of the frame.
//

import Foundation
import Metal
import MetalKit
import simd

// MARK: - Frame input

/// Everything the renderer needs from the game for one frame. A plain struct
/// with no back-reference to the model, so the render loop can never reach into
/// game state halfway through encoding and read something that is being mutated.
struct FrameInput {
    var environment = SimulationEnvironment()
    var atmosphere = AtmosphereState()
    var look: Look = Look.all[0]
    var dayFraction: Double = 0.45
    var cloudCover: Double = 0.5

    var cursorWorld = SIMD2<Float>.zero
    var cursorRadius: Float = 1
    var cursorVisible = false
    /// Draws the ring as a square instead of a circle, so the cursor tells the
    /// truth about the footprint the solver is about to apply.
    var cursorSquare = false

    var ghostVisible = false
    var ghostOrigin = SIMD2<Float>.zero
    var ghostRadius: Float = 1
    var ghostRotation: Float = 0
    var ghostShape: Int32 = 0
    var ghostDetail: Float = 8
    /// False only when there is a charge in the mould and it is too dry to
    /// survive being turned out. The ghost goes red rather than the player
    /// finding out a second later.
    var ghostWillHold = true

    var lanterns: [SKPointLight] = []
    var props: [SKProp] = []

    var highWater: Double = 0.3
    var paused = false
    var reducedMotion = false
}

// MARK: - Renderer

final class Renderer: NSObject {

    // MARK: Core

    let context: MetalContext
    private(set) var simulation: SandSimulation
    private(set) var tier: QualityTier

    let camera = Camera()

    // MARK: Pipelines

    private var pSky: MTLRenderPipelineState!
    private var pTerrain: MTLRenderPipelineState!
    private var pTerrainShadow: MTLRenderPipelineState!
    private var pWater: MTLRenderPipelineState!
    private var pProps: MTLRenderPipelineState!
    private var pPropsShadow: MTLRenderPipelineState!
    private var pParticles: MTLRenderPipelineState!
    private var pBright: MTLRenderPipelineState!
    private var pBlur: MTLRenderPipelineState!
    private var pComposite: MTLRenderPipelineState!
    private var cSkyBake: MTLComputePipelineState!

    private var dsSceneWrite: MTLDepthStencilState!
    private var dsSceneTestOnly: MTLDepthStencilState!
    private var dsAlways: MTLDepthStencilState!
    private var dsShadow: MTLDepthStencilState!

    // MARK: Targets

    private var sceneColor: MTLTexture?
    private var sceneCopy: MTLTexture?
    private var sceneDepth: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var shadowMap: MTLTexture?
    private var skyLUT: MTLTexture?

    private var drawableSize = CGSize(width: 1, height: 1)
    private var renderSize = CGSize(width: 1, height: 1)

    static let sceneFormat: MTLPixelFormat = .rgba16Float
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let skyLUTSize = (width: 256, height: 128)

    // MARK: Subsystems

    private(set) var particles: ParticleSystem
    private(set) var propRenderer: PropRenderer

    // MARK: Sky bake state

    private var lastBakedSun = SIMD3<Float>(0, -1, 0)
    private var lastBakedCloud: Double = -1
    private var skyNeedsBake = true

    // MARK: Frame pacing

    /// Triple buffering. Three is the number that keeps the CPU a frame ahead of
    /// the GPU without adding latency you can feel in a drawing tool — and this
    /// is a drawing tool.
    static let maxFramesInFlight = 3
    private let frameSemaphore = DispatchSemaphore(value: Renderer.maxFramesInFlight)

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private(set) var smoothedFrameDuration: Double = 1.0 / 60.0

    /// The ambient-occlusion pass is expensive and the sand moves slowly. Once
    /// every few frames is indistinguishable from every frame, and it is the
    /// single biggest saving available on a phone.
    private var framesSinceAO = 99
    private var aoInterval = 4

    // MARK: Public state

    var input = FrameInput()
    /// Set by the input layer; consumed and cleared on the next encoded frame.
    var pendingPickRay: (origin: SIMD3<Float>, direction: SIMD3<Float>)?

    // MARK: - Init

    init(context: MetalContext, tier: QualityTier) throws {
        self.context = context
        self.tier = tier
        self.simulation = try SandSimulation(context: context, tier: tier)
        self.particles = try ParticleSystem(context: context, tier: tier)
        self.propRenderer = try PropRenderer(context: context)
        super.init()

        try buildPipelines()
        try buildPersistentTargets()
    }

    private func buildPipelines() throws {
        let scene = [Renderer.sceneFormat]

        pSky = try context.renderPipeline(vertex: "sky_vertex", fragment: "sky_fragment",
                                          colorFormats: scene, depthFormat: Renderer.depthFormat,
                                          label: "sky")
        pTerrain = try context.renderPipeline(vertex: "terrain_vertex", fragment: "terrain_fragment",
                                              colorFormats: scene, depthFormat: Renderer.depthFormat,
                                              label: "terrain")
        pTerrainShadow = try context.renderPipeline(vertex: "terrain_shadow_vertex", fragment: "",
                                                    colorFormats: [], depthFormat: Renderer.depthFormat,
                                                    label: "terrain.shadow")
        pWater = try context.renderPipeline(vertex: "water_vertex", fragment: "water_fragment",
                                            colorFormats: scene, depthFormat: Renderer.depthFormat,
                                            label: "water")
        pParticles = try context.renderPipeline(vertex: "particle_vertex", fragment: "particle_fragment",
                                                colorFormats: scene, depthFormat: Renderer.depthFormat,
                                                blending: true, label: "particles")
        pBright = try context.renderPipeline(vertex: "post_vertex", fragment: "post_brightpass",
                                             colorFormats: scene, label: "bloom.bright")
        pBlur = try context.renderPipeline(vertex: "post_vertex", fragment: "post_blur",
                                           colorFormats: scene, label: "bloom.blur")
        cSkyBake = try context.computePipeline("sky_bake")

        // The props pipeline owns a vertex descriptor, so it is built by the prop
        // renderer that also owns the buffer layout it describes.
        pProps = try propRenderer.makePipeline(context: context,
                                               colorFormats: scene,
                                               depthFormat: Renderer.depthFormat)
        pPropsShadow = try propRenderer.makeShadowPipeline(context: context,
                                                           depthFormat: Renderer.depthFormat)

        let write = MTLDepthStencilDescriptor()
        write.depthCompareFunction = .less
        write.isDepthWriteEnabled = true
        dsSceneWrite = context.device.makeDepthStencilState(descriptor: write)

        let testOnly = MTLDepthStencilDescriptor()
        testOnly.depthCompareFunction = .less
        testOnly.isDepthWriteEnabled = false
        dsSceneTestOnly = context.device.makeDepthStencilState(descriptor: testOnly)

        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = false
        dsAlways = context.device.makeDepthStencilState(descriptor: always)

        let shadow = MTLDepthStencilDescriptor()
        shadow.depthCompareFunction = .lessEqual
        shadow.isDepthWriteEnabled = true
        dsShadow = context.device.makeDepthStencilState(descriptor: shadow)
    }

    private func buildPersistentTargets() throws {
        skyLUT = context.makeTexture(width: Renderer.skyLUTSize.width,
                                     height: Renderer.skyLUTSize.height,
                                     format: .rgba16Float,
                                     usage: [.shaderRead, .shaderWrite],
                                     label: "sky.lut")
        // Mips are how a rough surface asks for a blurry sky without a
        // convolution pass. Level 5 of a 256×128 LUT is a 8×4 image, which is
        // exactly the right amount of "the sky, roughly" for an ambient term.
        if let sky = skyLUT {
            let d = MTLTextureDescriptor()
            d.textureType = .type2D
            d.pixelFormat = .rgba16Float
            d.width = sky.width
            d.height = sky.height
            d.mipmapLevelCount = 7
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            let mipped = context.device.makeTexture(descriptor: d)
            mipped?.label = "sky.lut"
            skyLUT = mipped
        }

        let s = tier.shadowResolution
        shadowMap = context.makeTexture(width: s, height: s, format: Renderer.depthFormat,
                                        usage: [.renderTarget, .shaderRead], label: "shadow.map")

        guard skyLUT != nil, shadowMap != nil else { throw MetalSetupError.noDevice }
    }

    // MARK: - Resize

    func resize(drawableSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        drawableSize = size

        let scale = CGFloat(tier.renderScale)
        let target = CGSize(width: max((size.width * scale).rounded(), 1),
                            height: max((size.height * scale).rounded(), 1))
        if target == renderSize, sceneColor != nil { return }
        renderSize = target

        let w = Int(target.width), h = Int(target.height)
        sceneColor = context.makeTexture(width: w, height: h, format: Renderer.sceneFormat,
                                         usage: [.renderTarget, .shaderRead], label: "scene.color")
        sceneCopy = context.makeTexture(width: w, height: h, format: Renderer.sceneFormat,
                                        usage: [.renderTarget, .shaderRead], label: "scene.copy")
        sceneDepth = context.makeTexture(width: w, height: h, format: Renderer.depthFormat,
                                         usage: [.renderTarget, .shaderRead], label: "scene.depth")
        let bw = max(w / 2, 1), bh = max(h / 2, 1)
        bloomA = context.makeTexture(width: bw, height: bh, format: Renderer.sceneFormat,
                                     usage: [.renderTarget, .shaderRead], label: "bloom.a")
        bloomB = context.makeTexture(width: bw, height: bh, format: Renderer.sceneFormat,
                                     usage: [.renderTarget, .shaderRead], label: "bloom.b")
    }

    /// Rebuild everything that depends on the quality tier. Called when the
    /// player changes it, and — importantly — the simulation is rebuilt too, so
    /// the caller must re-seed the beach afterwards.
    func apply(tier newTier: QualityTier) throws {
        guard newTier != tier else { return }
        tier = newTier
        simulation = try SandSimulation(context: context, tier: newTier)
        particles = try ParticleSystem(context: context, tier: newTier)
        try buildPersistentTargets()
        sceneColor = nil
        resize(drawableSize: drawableSize)
        skyNeedsBake = true
    }

    // MARK: - Uniforms

    private func frameUniforms(aspect: Float) -> SKFrameUniforms {
        var f = SKFrameUniforms()
        let view = camera.viewMatrix()
        let projection = camera.projectionMatrix(aspect: aspect)
        let vp = projection * view

        f.view = view
        f.viewProjection = vp
        f.inverseViewProjection = vp.inverse
        f.lightViewProjection = Camera.lightMatrix(sunDirection: input.atmosphere.sunDirection,
                                                   domain: SandSimulation.domain)

        f.cameraPosition = SIMD4(camera.position, tan(camera.fieldOfView * 0.5))
        f.sunDirection = SIMD4(input.atmosphere.sunDirection, input.atmosphere.sunElevation)
        f.sunColor = SIMD4(input.atmosphere.sunColor, 1)
        f.moonDirection = SIMD4(input.atmosphere.moonDirection, input.atmosphere.moonPhase)
        f.moonColor = SIMD4(input.atmosphere.moonColor, input.atmosphere.moonPhase)
        f.domain = SandSimulation.domain
        f.viewport = SIMD4(Float(renderSize.width), Float(renderSize.height),
                           1 / Float(renderSize.width), 1 / Float(renderSize.height))

        let res = Float(simulation.resolution)
        f.texel = SIMD2(1 / res, 1 / res)
        f.simResolution = res
        f.time = Float(input.environment.time)
        f.seaBase = Float(input.environment.seaBase)
        f.waveAmplitude = Float(input.environment.waveAmplitude)
        f.fogK = input.atmosphere.fogK
        f.exposure = input.atmosphere.exposure
        f.night = input.atmosphere.night
        f.shadowTexel = 1 / Float(tier.shadowResolution)
        f.shadowEnabled = 1
        f.look = input.look.id.rawValue
        f.dayFraction = Float(input.dayFraction)
        f.contactShadowStrength = 1
        return f
    }

    private func lookUniforms() -> SKLookUniforms {
        let l = input.look
        var u = SKLookUniforms()
        u.sandTint = SIMD4(l.sandTint, l.sandRoughness)
        u.wetTint = SIMD4(l.wetTint, l.wetSpecular)
        u.waterTint = SIMD4(l.waterTint, l.microDetail)
        u.foamTint = SIMD4(l.foamTint, l.outline)
        u.bandCount = l.bandCount
        u.bandSoftness = l.bandSoftness
        u.screenAngle = l.screenAngle
        u.screenScale = l.screenScale
        u.exposure = l.exposure
        u.contrast = l.contrast
        u.saturation = l.saturation
        u.bloom = l.bloom
        u.vignette = l.vignette
        u.grain = l.grain
        u.chromatic = l.chromatic
        u.contourInterval = l.contourInterval
        u.treatment = l.treatment.rawValue
        u.index = l.id.rawValue
        return u
    }

    private func terrainUniforms(gridEdge: Int, outer: Bool) -> SKTerrainUniforms {
        var t = SKTerrainUniforms()
        t.gridEdge = Float(gridEdge)
        t.outer = outer ? 1 : 0
        t.cell = simulation.cellSize
        t.lanternCount = Float(min(input.lanterns.count, 16))
        // w is a small enum rather than a flag: 0 hidden, 1 round, 2 square. The
        // shader's existing `> 0.5` visibility test still reads correctly.
        var cursorMode: Float = 0
        if input.cursorVisible { cursorMode = input.cursorSquare ? 2 : 1 }
        t.cursor = SIMD4(input.cursorWorld.x, input.cursorWorld.y,
                         input.cursorRadius, cursorMode)
        t.ghost = SIMD4(input.ghostRadius, input.ghostRotation,
                        Float(input.ghostShape), input.ghostVisible ? 1 : 0)
        let willHold: Float = input.ghostWillHold ? 1 : 0
        t.ghost2 = SIMD4(input.ghostDetail, willHold, 0, 0)
        t.ghostOrigin = SIMD4(input.ghostOrigin.x, input.ghostOrigin.y, 0, 0)
        return t
    }

    private func postUniforms() -> SKPostUniforms {
        let l = input.look
        var p = SKPostUniforms()
        p.viewport = SIMD4(Float(renderSize.width), Float(renderSize.height),
                           1 / Float(renderSize.width), 1 / Float(renderSize.height))
        p.exposure = input.atmosphere.exposure * l.exposure
        p.bloomStrength = tier.wantsBloom ? l.bloom : 0
        p.vignette = l.vignette
        p.grain = input.reducedMotion ? l.grain * 0.35 : l.grain
        p.time = Float(input.environment.time)
        p.night = input.atmosphere.night
        p.look = l.id.rawValue
        p.transition = 0
        p.chromatic = l.chromatic
        p.contrast = l.contrast
        p.saturation = l.saturation
        p.inkOutline = l.outline
        p.nearPlane = camera.nearPlane
        p.farPlane = camera.farPlane

        // Depth of field only for the looks that are pretending to be a small
        // physical object. Focus follows the camera's own pivot distance, which
        // is by definition what the player is looking at.
        if l.treatment == .banded {
            p.focusDistance = max(length(camera.position - input.cameraFocusOrNil), 1)
            p.aperture = 0.30
        } else {
            p.focusDistance = 10
            p.aperture = 0
        }

        let scale = tier.renderScale
        if scale > 1.001 {
            p.resolveTexel = SIMD2(0.5 / Float(renderSize.width), 0.5 / Float(renderSize.height))
            p.resolveStrength = min((scale - 1) * 2.2, 1)
        } else {
            p.resolveTexel = .zero
            p.resolveStrength = 0
        }
        return p
    }

    private func skyUniforms() -> SKSkyUniforms {
        var s = SKSkyUniforms()
        s.sunDirection = SIMD4(input.atmosphere.sunDirection, input.atmosphere.sunElevation)
        s.moonDirection = SIMD4(input.atmosphere.moonDirection, input.atmosphere.moonPhase)
        s.groundAlbedo = SIMD4(0.42, 0.37, 0.29, 0)
        s.turbidity = 2.2 + Float(input.cloudCover) * 1.8
        s.cloudCover = Float(input.cloudCover)
        s.cloudDrift = Float(input.environment.time) * 6.5
        s.time = Float(input.environment.time)
        s.rayleighScale = 1
        s.mieScale = 1
        s.exposure = input.atmosphere.exposure
        s.look = input.look.id.rawValue
        return s
    }

    // MARK: - Frame

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let sceneColor, let sceneCopy, let sceneDepth,
              let bloomA, let bloomB, let shadowMap, let skyLUT else { return }

        let now = CACurrentMediaTime()
        var dt = now - lastFrameTime
        lastFrameTime = now
        // A frame that took longer than 100 ms is a stall, not slow motion.
        // Simulating it would deliver a tenth of a second of avalanche at once.
        dt = min(max(dt, 1.0 / 240.0), 0.1)
        smoothedFrameDuration += (dt - smoothedFrameDuration) * 0.1

        frameSemaphore.wait()
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }
        commandBuffer.label = "sandkraft.frame"
        commandBuffer.addCompletedHandler { [semaphore = frameSemaphore] _ in semaphore.signal() }

        let aspect = Float(renderSize.width / max(renderSize.height, 1))
        var frame = frameUniforms(aspect: aspect)
        var look = lookUniforms()

        // MARK: Sky bake
        //
        // Only when the sun has actually moved. At "Held" day speed this runs
        // once and the atmosphere costs nothing for the rest of the session.
        let sunDelta = distance(input.atmosphere.sunDirection, lastBakedSun)
        if skyNeedsBake || sunDelta > 0.0035 || abs(input.cloudCover - lastBakedCloud) > 0.01 {
            var sky = skyUniforms()
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "sky.bake"
                encoder.setComputePipelineState(cSkyBake)
                encoder.setTexture(skyLUT, index: 0)
                encoder.setBytes(&sky, length: MemoryLayout<SKSkyUniforms>.stride, index: 0)
                context.dispatch(encoder, pipeline: cSkyBake,
                                 width: skyLUT.width, height: skyLUT.height)
                encoder.endEncoding()
            }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "sky.mips"
                blit.generateMipmaps(for: skyLUT)
                blit.endEncoding()
            }
            lastBakedSun = input.atmosphere.sunDirection
            lastBakedCloud = input.cloudCover
            skyNeedsBake = false
        }

        // MARK: Simulation
        if !input.paused {
            simulation.step(environment: input.environment,
                            dt: dt, substeps: tier.substeps, in: commandBuffer)
            particles.update(environment: input.environment,
                             dt: Float(dt),
                             sandTexture: simulation.sand,
                             depositBuffer: simulation.depositBuffer,
                             in: commandBuffer)
        }

        framesSinceAO += 1
        if framesSinceAO >= aoInterval {
            simulation.updateAmbientOcclusion(environment: input.environment, in: commandBuffer)
            framesSinceAO = 0
        }

        simulation.measure(environment: input.environment,
                           highWater: input.highWater, in: commandBuffer)

        if let ray = pendingPickRay {
            simulation.raycast(origin: ray.origin, direction: ray.direction,
                               environment: input.environment, in: commandBuffer)
            pendingPickRay = nil
        }

        // MARK: Shadow
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
            encoder.label = "shadow"
            encoder.setDepthStencilState(dsShadow)
            encoder.setCullMode(.none)

            var shadowTerrain = terrainUniforms(gridEdge: tier.terrainGrid, outer: false)
            encoder.setRenderPipelineState(pTerrainShadow)
            encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setVertexBytes(&shadowTerrain, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.setVertexTexture(simulation.sand, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: Renderer.gridVertexCount(tier.terrainGrid))

            propRenderer.encodeShadow(encoder: encoder, pipeline: pPropsShadow,
                                      props: input.props, frame: &frame)
            encoder.endEncoding()
        }

        // MARK: Opaque
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = sceneColor
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scenePass.depthAttachment.texture = sceneDepth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .store
        scenePass.depthAttachment.clearDepth = 1

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "opaque"
            encoder.setCullMode(.none)
            var sky = skyUniforms()

            // Sky first, with depth writes off — it is the background, and
            // everything else is allowed to draw over it.
            encoder.setRenderPipelineState(pSky)
            encoder.setDepthStencilState(dsAlways)
            encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&sky, length: MemoryLayout<SKSkyUniforms>.stride, index: 1)
            encoder.setFragmentTexture(skyLUT, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            encoder.setDepthStencilState(dsSceneWrite)
            encoder.setRenderPipelineState(pTerrain)
            encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&look, length: MemoryLayout<SKLookUniforms>.stride, index: 2)
            encoder.setVertexTexture(simulation.sand, index: 0)
            encoder.setFragmentTexture(simulation.sand, index: 0)
            encoder.setFragmentTexture(simulation.ambientOcclusion, index: 1)
            encoder.setFragmentTexture(skyLUT, index: 2)
            encoder.setFragmentTexture(shadowMap, index: 3)
            encodeLanterns(encoder: encoder, index: 3)

            // The skirt goes first and is pushed back in *depth*, not in height,
            // so its coarse triangles lose every argument with the fine ones
            // without leaving a geometric step at the border.
            var skirt = terrainUniforms(gridEdge: tier.skirtGrid, outer: true)
            encoder.setDepthBias(2.0, slopeScale: 4.0, clamp: 0.01)
            encoder.setVertexBytes(&skirt, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&skirt, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: Renderer.gridVertexCount(tier.skirtGrid))

            var inner = terrainUniforms(gridEdge: tier.terrainGrid, outer: false)
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
            encoder.setVertexBytes(&inner, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&inner, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: Renderer.gridVertexCount(tier.terrainGrid))

            propRenderer.encode(encoder: encoder, pipeline: pProps, props: input.props,
                                frame: &frame, look: &look,
                                skyLUT: skyLUT, shadowMap: shadowMap)
            encoder.endEncoding()
        }

        // MARK: Copy for refraction
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "scene.copy"
            blit.copy(from: sceneColor, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: sceneColor.width, height: sceneColor.height, depth: 1),
                      to: sceneCopy, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }

        // MARK: Water and particles
        let waterPass = MTLRenderPassDescriptor()
        waterPass.colorAttachments[0].texture = sceneColor
        waterPass.colorAttachments[0].loadAction = .load
        waterPass.colorAttachments[0].storeAction = .store
        waterPass.depthAttachment.texture = sceneDepth
        waterPass.depthAttachment.loadAction = .load
        waterPass.depthAttachment.storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: waterPass) {
            encoder.label = "water+particles"
            encoder.setCullMode(.none)

            var water = terrainUniforms(gridEdge: tier.waterGrid, outer: true)
            encoder.setRenderPipelineState(pWater)
            encoder.setDepthStencilState(dsSceneWrite)
            encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setVertexBytes(&water, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&water, length: MemoryLayout<SKTerrainUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&look, length: MemoryLayout<SKLookUniforms>.stride, index: 2)
            encoder.setVertexTexture(simulation.sand, index: 0)
            encoder.setFragmentTexture(simulation.sand, index: 0)
            encoder.setFragmentTexture(skyLUT, index: 1)
            encoder.setFragmentTexture(sceneCopy, index: 2)
            encoder.setFragmentTexture(shadowMap, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: Renderer.gridVertexCount(tier.waterGrid))

            encoder.setRenderPipelineState(pParticles)
            encoder.setDepthStencilState(dsSceneTestOnly)
            particles.encodeDraw(encoder: encoder, frame: &frame)
            encoder.endEncoding()
        }

        // MARK: Bloom
        var post = postUniforms()
        if tier.wantsBloom && post.bloomStrength > 0.001 {
            encodeFullScreen(commandBuffer, pipeline: pBright, target: bloomA,
                             label: "bloom.bright", post: &post) { encoder in
                encoder.setFragmentTexture(sceneColor, index: 0)
            }
            var half = post
            half.viewport = SIMD4(Float(bloomA.width), Float(bloomA.height),
                                  1 / Float(bloomA.width), 1 / Float(bloomA.height))
            var horizontal = SIMD2<Float>(1, 0)
            var vertical = SIMD2<Float>(0, 1)
            encodeFullScreen(commandBuffer, pipeline: pBlur, target: bloomB,
                             label: "bloom.h", post: &half) { encoder in
                encoder.setFragmentTexture(bloomA, index: 0)
                encoder.setFragmentBytes(&horizontal, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            }
            encodeFullScreen(commandBuffer, pipeline: pBlur, target: bloomA,
                             label: "bloom.v", post: &half) { encoder in
                encoder.setFragmentTexture(bloomB, index: 0)
                encoder.setFragmentBytes(&vertical, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            }
        } else {
            post.bloomStrength = 0
        }

        // MARK: Composite
        if let composite = view.currentRenderPassDescriptor {
            composite.colorAttachments[0].loadAction = .dontCare
            composite.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: composite) {
                encoder.label = "composite"
                encoder.setRenderPipelineState(compositePipeline(for: view))
                encoder.setFragmentBytes(&post, length: MemoryLayout<SKPostUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&look, length: MemoryLayout<SKLookUniforms>.stride, index: 1)
                encoder.setFragmentTexture(sceneColor, index: 0)
                encoder.setFragmentTexture(post.bloomStrength > 0 ? bloomA : sceneColor, index: 1)
                encoder.setFragmentTexture(sceneDepth, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    static func gridVertexCount(_ edge: Int) -> Int {
        let w = max(edge - 1, 1)
        return w * w * 6
    }

    private var cachedComposite: (format: MTLPixelFormat, pipeline: MTLRenderPipelineState)?

    /// The drawable's pixel format is a property of the view, not of us, and on
    /// macOS it can change when a window moves between an SDR and an HDR display.
    private func compositePipeline(for view: MTKView) -> MTLRenderPipelineState {
        let format = view.colorPixelFormat
        if let cached = cachedComposite, cached.format == format { return cached.pipeline }
        // Force-try is deliberate: the shader is compiled into the app, so a
        // failure here is a build error that shipped, not a runtime condition.
        let pipeline = try! context.renderPipeline(vertex: "post_vertex", fragment: "post_composite",
                                                   colorFormats: [format], label: "composite")
        cachedComposite = (format, pipeline)
        pComposite = pipeline
        return pipeline
    }

    private func encodeFullScreen(_ commandBuffer: MTLCommandBuffer,
                                  pipeline: MTLRenderPipelineState,
                                  target: MTLTexture,
                                  label: String,
                                  post: inout SKPostUniforms,
                                  configure: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = label
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&post, length: MemoryLayout<SKPostUniforms>.stride, index: 0)
        configure(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeLanterns(encoder: MTLRenderCommandEncoder, index: Int) {
        var lights = input.lanterns
        if lights.isEmpty {
            // setFragmentBytes rejects a zero length, and an unbound buffer that
            // the shader's loop never enters is still a validation error.
            lights = [SKPointLight()]
        }
        lights.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            encoder.setFragmentBytes(base,
                                     length: MemoryLayout<SKPointLight>.stride * buffer.count,
                                     index: index)
        }
    }
}

// MARK: - Focus helper

private extension FrameInput {
    /// The point the depth-of-field focuses on. Kept here rather than on the
    /// camera because it is a *look* decision, and the camera should not know
    /// which art style is switched on.
    var cameraFocusOrNil: SIMD3<Float> {
        SIMD3(cursorWorld.x, 0, cursorWorld.y)
    }
}
