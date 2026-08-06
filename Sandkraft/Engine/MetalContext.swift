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
    var simResolution: Int {
        switch self {
        case .low:    return 256
        case .medium: return 384
        case .high:   return 512
        case .ultra:  return 640
        }
    }

    var shadowResolution: Int {
        switch self {
        case .low:    return 1024
        case .medium: return 1536
        case .high:   return 2048
        case .ultra:  return 2048
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
        case .low:    return 256
        case .medium: return 320
        case .high:   return 448
        case .ultra:  return 576
        }
    }

    /// The coarse sheet that carries the coast out to ±340 m.
    var skirtGrid: Int {
        switch self {
        case .low:    return 160
        case .medium: return 192
        case .high:   return 224
        case .ultra:  return 256
        }
    }

    var waterGrid: Int {
        switch self {
        case .low:    return 160
        case .medium: return 200
        case .high:   return 248
        case .ultra:  return 296
        }
    }

    /// Offscreen resolution as a multiple of the drawable. Above 1 this is plain
    /// supersampling, which is the least clever and most reliable anti-aliasing
    /// there is — and it anti-aliases the procedural noise and the contour lines,
    /// which MSAA cannot touch because they are shading, not geometry.
    var renderScale: Float {
        switch self {
        case .low:    return 0.90
        case .medium: return 1.00
        case .high:   return 1.15
        case .ultra:  return 1.30
        }
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
        return (field * fields + shadow + particles) / (1024 * 1024)
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
    var recommendedTier: QualityTier {
        #if os(macOS)
        return device.supportsFamily(.apple7) ? .ultra : .high
        #else
        if device.supportsFamily(.apple8) { return .high }
        if device.supportsFamily(.apple6) { return .medium }
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
