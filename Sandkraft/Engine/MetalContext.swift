//
//  MetalContext.swift
//  Sandkraft
//
//  Device, queue, library and a small pipeline cache. Everything GPU-shaped in
//  the app takes one of these rather than reaching for
//  MTLCreateSystemDefaultDevice() on its own, which keeps the number of places
//  that can fail at launch down to one.
//

import Foundation
import Metal
import QuartzCore

enum MetalSetupError: LocalizedError {
    case noDevice
    case noQueue
    case noLibrary
    case missingFunction(String)
    case pipelineFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "This device has no Metal GPU available."
        case .noQueue:
            return "Could not create a Metal command queue."
        case .noLibrary:
            return "The shader library failed to load."
        case .missingFunction(let name):
            return "Shader function “\(name)” is missing from the library."
        case .pipelineFailed(let name, let error):
            return "Pipeline “\(name)” failed to build: \(error.localizedDescription)"
        }
    }
}

/// How much work the simulation and renderer are allowed to do. Chosen once at
/// launch from the device, and adjustable by the player afterwards.
enum QualityTier: Int, CaseIterable, Identifiable, Codable, Sendable {
    case low = 0, medium = 1, high = 2, ultra = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .low:    return "Battery"
        case .medium: return "Balanced"
        case .high:   return "Detail"
        case .ultra:  return "Maximum"
        }
    }

    var note: String {
        switch self {
        case .low:    return "Coolest and quietest. Still a full simulation."
        case .medium: return "The default on most devices."
        case .high:   return "Sharper sand, softer shadows."
        case .ultra:  return "For Macs and the newest iPhones."
        }
    }

    /// Edge length of the square sand texture. Everything else scales off this.
    ///
    /// These went up by a quarter when the beach did, so the cell stays where it
    /// was — a 60 m square at 448² is 13.4 cm per cell, which is the same sand
    /// the 48 m square gave at 384². A wider beach at the old resolutions would
    /// have been a coarser one, and coarse sand is a different game: the cell is
    /// the smallest feature a wall can have, and it is what the angle of repose
    /// is resolved against.
    ///
    /// Multiples of sixteen, because `metrics_partial` reduces across a 16 × 16
    /// threadgroup and a resolution that is not a multiple of it wastes a whole
    /// row and column of threads on the bounds check.
    var simResolution: Int {
        switch self {
        case .low:    return 320
        case .medium: return 448
        case .high:   return 576
        case .ultra:  return 704
        }
    }

    /// The shadow map is fitted to the domain, so a wider beach spreads the same
    /// texels over more ground. Raised to hold roughly the old texel density.
    var shadowResolution: Int {
        switch self {
        case .low:    return 1280
        case .medium: return 1792
        case .high:   return 2048
        case .ultra:  return 2560
        }
    }

    /// Solver substeps per rendered frame. More substeps means a stiffer, more
    /// accurate avalanche at linear cost, and it is the first thing to cut.
    var substeps: Int {
        switch self {
        case .low:    return 2
        case .medium: return 3
        case .high:   return 4
        case .ultra:  return 5
        }
    }

    var particleCapacity: Int {
        switch self {
        case .low:    return 8_000
        case .medium: return 20_000
        case .high:   return 48_000
        case .ultra:  return 96_000
        }
    }

    /// Undo depth. Each step is a full copy of the sand texture, so this is the
    /// one setting that costs real memory.
    var undoDepth: Int {
        switch self {
        case .low:    return 6
        case .medium: return 8
        case .high:   return 12
        case .ultra:  return 16
        }
    }

    /// Vertices along one edge of the displaced beach mesh. Independent of the
    /// simulation resolution: the fragment shader rebuilds the normal from the
    /// field anyway, so a slightly coarser mesh costs silhouette crispness and
    /// nothing else.
    var terrainGrid: Int {
        switch self {
        case .low:    return 224
        case .medium: return 336
        case .high:   return 448
        case .ultra:  return 560
        }
    }

    /// The coarse sheet that carries the coast out to ±340 m. Barely moved: it
    /// covers the same distance it always did, and a wider simulated square only
    /// means the skirt has slightly less of it to draw.
    var skirtGrid: Int {
        switch self {
        case .low:    return 128
        case .medium: return 160
        case .high:   return 192
        case .ultra:  return 224
        }
    }

    var waterGrid: Int {
        switch self {
        case .low:    return 160
        case .medium: return 200
        case .high:   return 240
        case .ultra:  return 272
        }
    }

    /// Offscreen resolution as a multiple of the drawable. Above 1 this is plain
    /// supersampling, which is the least clever and most reliable anti-aliasing
    /// there is — and it anti-aliases the procedural noise and the contour lines,
    /// which MSAA cannot touch because they are shading, not geometry.
    var renderScale: Float {
        switch self {
        case .low:    return 0.85
        case .medium: return 1.00
        case .high:   return 1.10
        case .ultra:  return 1.25
        }
    }

    /// Vertex count of the beach mesh, for the settings screen. Computed here as
    /// plain arithmetic for the same reason as `frameTimeDescription`.
    var meshDescription: String {
        let edge = terrainGrid - 1
        let vertices = edge * edge * 6
        return "\(vertices / 1000)k vertices"
    }

    var wantsBloom: Bool { self != .low }
    var wantsSoftShadows: Bool { self.rawValue >= QualityTier.medium.rawValue }

    /// Approximate cost of the sand texture pool, for the settings screen. Being
    /// straight with people about what "Maximum" costs is cheaper than a support
    /// email about thermals.
    var approximateMemoryMB: Int {
        let texel = 16                                       // RGBA32Float
        let field = simResolution * simResolution * texel
        let fields = 2 + 1 + 1 + undoDepth                   // ping, pong, pristine, deposit, undo
        let shadow = shadowResolution * shadowResolution * 4
        let particles = particleCapacity * 48
        // The baked hardpack table. The same 8 MB at every tier — it describes
        // the shore, which does not get bigger when the simulation does.
        let bedrock = SandSimulation.bedrockResolution * SandSimulation.bedrockResolution * 8
        return (field * fields + shadow + particles + bedrock) / (1024 * 1024)
    }
}

final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    /// Non-uniform threadgroup dispatch is available on every Apple GPU we ship
    /// on, but not on some older Intel Macs. Where it is missing we round the
    /// grid up and bounds-check in the kernel, which every kernel here does
    /// anyway.
    let supportsNonUniformThreadgroups: Bool

    private var computeCache: [String: MTLComputePipelineState] = [:]
    private let cacheLock = NSLock()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MetalSetupError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalSetupError.noQueue }
        guard let library = device.makeDefaultLibrary() else { throw MetalSetupError.noLibrary }

        self.device = device
        self.commandQueue = queue
        self.library = library
        self.commandQueue.label = "Sandkraft"

        #if os(macOS)
        self.supportsNonUniformThreadgroups = device.supportsFamily(.apple4) || device.supportsFamily(.mac2)
        #else
        self.supportsNonUniformThreadgroups = device.supportsFamily(.apple4)
        #endif
    }

    /// The tier this device can comfortably hold, before the player overrides it.
    ///
    /// Two rules, both learned the hard way:
    ///
    ///   · **Never auto-select `.ultra`.** "Maximum" is a thing somebody chooses
    ///     after deciding they want their fans on, not a default.
    ///   · **`supportsFamily` says what a GPU can *do*, not how big it is.** An M1
    ///     Air and an M3 Max are both `.apple7`, and picking a tier off that alone
    ///     hands a fanless laptop a 640² simulation and two million vertices.
    ///     Working-set size is the cheapest honest proxy Metal exposes for size.
    var recommendedTier: QualityTier {
        let workingSet = device.recommendedMaxWorkingSetSize
        let gigabyte: UInt64 = 1024 * 1024 * 1024

        #if os(macOS)
        // Intel integrated graphics: everything below is beyond them.
        guard device.supportsFamily(.apple7) else { return .low }
        if workingSet >= 24 * gigabyte { return .high }        // Max / Ultra parts
        if workingSet >= 12 * gigabyte { return .medium }      // Pro parts, 16 GB+
        return .medium                                          // base M-series
        #else
        if device.supportsFamily(.apple8), workingSet >= 5 * gigabyte { return .medium }
        if device.supportsFamily(.apple7) { return .low }
        return .low
        #endif
    }

    // MARK: - Pipelines

    func computePipeline(_ name: String) throws -> MTLComputePipelineState {
        cacheLock.lock()
        if let cached = computeCache[name] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let function = library.makeFunction(name: name) else {
            throw MetalSetupError.missingFunction(name)
        }
        do {
            let pipeline = try device.makeComputePipelineState(function: function)
            cacheLock.lock()
            computeCache[name] = pipeline
            cacheLock.unlock()
            return pipeline
        } catch {
            throw MetalSetupError.pipelineFailed(name, error)
        }
    }

    func renderPipeline(vertex: String,
                        fragment: String,
                        colorFormats: [MTLPixelFormat],
                        depthFormat: MTLPixelFormat = .invalid,
                        blending: Bool = false,
                        label: String? = nil) throws -> MTLRenderPipelineState {
        guard let vfn = library.makeFunction(name: vertex) else {
            throw MetalSetupError.missingFunction(vertex)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label ?? "\(vertex)/\(fragment)"
        descriptor.vertexFunction = vfn

        if !fragment.isEmpty {
            guard let ffn = library.makeFunction(name: fragment) else {
                throw MetalSetupError.missingFunction(fragment)
            }
            descriptor.fragmentFunction = ffn
        }

        for (index, format) in colorFormats.enumerated() {
            guard let attachment = descriptor.colorAttachments[index] else { continue }
            attachment.pixelFormat = format
            if blending {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }
        descriptor.depthAttachmentPixelFormat = depthFormat

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalSetupError.pipelineFailed(descriptor.label ?? vertex, error)
        }
    }

    // MARK: - Resources

    func makeTexture(width: Int,
                     height: Int,
                     format: MTLPixelFormat,
                     usage: MTLTextureUsage,
                     storage: MTLStorageMode = .private,
                     label: String) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = .type2D
        d.pixelFormat = format
        d.width = max(width, 1)
        d.height = max(height, 1)
        d.mipmapLevelCount = 1
        d.usage = usage
        d.storageMode = storage
        let texture = device.makeTexture(descriptor: d)
        texture?.label = label
        return texture
    }

    func makeBuffer(length: Int, storage: MTLResourceOptions = .storageModeShared, label: String) -> MTLBuffer? {
        let buffer = device.makeBuffer(length: max(length, 16), options: storage)
        buffer?.label = label
        return buffer
    }

    // MARK: - Dispatch

    /// Dispatch over a 2D grid, using non-uniform threadgroups where available
    /// and rounding up where it is not. Every kernel in this project bounds-
    /// checks its own `gid`, so both paths are safe.
    func dispatch(_ encoder: MTLComputeCommandEncoder,
                  pipeline: MTLComputePipelineState,
                  width: Int,
                  height: Int) {
        let w = min(pipeline.threadExecutionWidth, 16)
        let h = min(max(pipeline.maxTotalThreadsPerThreadgroup / w, 1), 16)
        let threadgroup = MTLSize(width: w, height: h, depth: 1)

        if supportsNonUniformThreadgroups {
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: threadgroup)
        } else {
            let groups = MTLSize(width: (width + w - 1) / w,
                                 height: (height + h - 1) / h,
                                 depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
        }
    }

    /// Dispatch over a 1D grid with a fixed threadgroup size. Used for the metric
    /// reduction, which relies on a specific threadgroup width.
    func dispatch1D(_ encoder: MTLComputeCommandEncoder,
                    count: Int,
                    threadsPerGroup: Int) {
        let groups = MTLSize(width: max((count + threadsPerGroup - 1) / threadsPerGroup, 1),
                             height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups,
                                     threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
    }
}
