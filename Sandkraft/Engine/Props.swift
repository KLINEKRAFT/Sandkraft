//
//  Props.swift
//  Sandkraft
//
//  Adornment geometry, built on the CPU at launch, and the instanced renderer
//  that draws it.
//
//  The clever version of this file synthesises twelve objects in a vertex
//  shader from an instance index. It would be shorter and it would be a mistake:
//  one enormous switch that cannot be stepped through in the GPU debugger,
//  cannot be unit-tested, and re-derives identical geometry sixty times a
//  second. A few thousand triangles built once costs about 200 KB and can be
//  read.
//

import Foundation
import Metal
import simd

// MARK: - Mesh building

struct PropVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>      // rgb albedo, a = roughness
}

/// A small triangle-soup builder. Non-indexed on purpose: these meshes are
/// hundreds of triangles, and an index buffer would save less memory than the
/// code to manage it costs in attention.
struct MeshBuilder {
    private(set) var vertices: [PropVertex] = []

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                           color: SIMD4<Float>, normal: SIMD3<Float>? = nil) {
        let n = normal ?? normalize(cross(b - a, c - a))
        vertices.append(PropVertex(position: a, normal: n, color: color))
        vertices.append(PropVertex(position: b, normal: n, color: color))
        vertices.append(PropVertex(position: c, normal: n, color: color))
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                       _ c: SIMD3<Float>, _ d: SIMD3<Float>, color: SIMD4<Float>) {
        triangle(a, b, c, color: color)
        triangle(a, c, d, color: color)
    }

    mutating func box(centre: SIMD3<Float>, size: SIMD3<Float>, color: SIMD4<Float>) {
        let h = size * 0.5
        let p = [
            centre + SIMD3(-h.x, -h.y, -h.z), centre + SIMD3( h.x, -h.y, -h.z),
            centre + SIMD3( h.x,  h.y, -h.z), centre + SIMD3(-h.x,  h.y, -h.z),
            centre + SIMD3(-h.x, -h.y,  h.z), centre + SIMD3( h.x, -h.y,  h.z),
            centre + SIMD3( h.x,  h.y,  h.z), centre + SIMD3(-h.x,  h.y,  h.z)
        ]
        quad(p[4], p[5], p[6], p[7], color: color)   // +z
        quad(p[1], p[0], p[3], p[2], color: color)   // −z
        quad(p[5], p[1], p[2], p[6], color: color)   // +x
        quad(p[0], p[4], p[7], p[3], color: color)   // −x
        quad(p[3], p[7], p[6], p[2], color: color)   // +y
        quad(p[0], p[1], p[5], p[4], color: color)   // −y
    }

    mutating func cylinder(base: SIMD3<Float>, height: Float, radius: Float,
                           segments: Int = 10, color: SIMD4<Float>, capped: Bool = true) {
        let top = base + SIMD3(0, height, 0)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let d0 = SIMD3(cos(a0), 0, sin(a0))
            let d1 = SIMD3(cos(a1), 0, sin(a1))
            let b0 = base + d0 * radius, b1 = base + d1 * radius
            let t0 = top + d0 * radius, t1 = top + d1 * radius
            triangle(b0, b1, t1, color: color, normal: d0)
            triangle(b0, t1, t0, color: color, normal: d0)
            if capped {
                triangle(top, t0, t1, color: color, normal: SIMD3(0, 1, 0))
                triangle(base, b1, b0, color: color, normal: SIMD3(0, -1, 0))
            }
        }
    }

    mutating func cone(base: SIMD3<Float>, height: Float, radius: Float,
                       segments: Int = 14, color: SIMD4<Float>) {
        let apex = base + SIMD3(0, height, 0)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let p0 = base + SIMD3(cos(a0), 0, sin(a0)) * radius
            let p1 = base + SIMD3(cos(a1), 0, sin(a1)) * radius
            triangle(p0, p1, apex, color: color)
            triangle(base, p1, p0, color: color, normal: SIMD3(0, -1, 0))
        }
    }

    mutating func disc(centre: SIMD3<Float>, radius: Float, segments: Int = 16,
                       color: SIMD4<Float>, normal: SIMD3<Float> = SIMD3(0, 1, 0)) {
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * 2 * .pi
            let a1 = Float(i + 1) / Float(segments) * 2 * .pi
            let p0 = centre + SIMD3(cos(a0), 0, sin(a0)) * radius
            let p1 = centre + SIMD3(cos(a1), 0, sin(a1)) * radius
            triangle(centre, p0, p1, color: color, normal: normal)
        }
    }
}

// MARK: - The library

enum PropMeshLibrary {

    /// Vertex ranges into the shared buffer, indexed by `AdornmentID.kindIndex`.
    struct Built {
        var vertices: [PropVertex]
        var ranges: [Range<Int>]
    }

    private static let wood = SIMD4<Float>(0.52, 0.40, 0.28, 0.85)
    private static let paleWood = SIMD4<Float>(0.74, 0.63, 0.45, 0.80)
    private static let metal = SIMD4<Float>(0.72, 0.74, 0.76, 0.28)
    private static let cloth = SIMD4<Float>(0.88, 0.32, 0.28, 0.95)
    private static let cloth2 = SIMD4<Float>(0.96, 0.92, 0.84, 0.95)
    private static let plastic = SIMD4<Float>(0.20, 0.55, 0.82, 0.35)
    private static let stone = SIMD4<Float>(0.52, 0.50, 0.47, 0.90)
    private static let shell = SIMD4<Float>(0.92, 0.86, 0.78, 0.55)
    private static let weed = SIMD4<Float>(0.24, 0.34, 0.20, 0.88)
    private static let glass = SIMD4<Float>(0.42, 0.62, 0.48, 0.15)

    static func build() -> Built {
        var builder = MeshBuilder()
        var ranges: [Range<Int>] = []

        func kind(_ body: (inout MeshBuilder) -> Void) {
            let start = builder.vertices.count
            body(&builder)
            ranges.append(start..<builder.vertices.count)
        }

        // 0 · Pennant — a pole and a triangle that hangs off it.
        kind { b in
            b.cylinder(base: .zero, height: 0.62, radius: 0.010, segments: 6, color: paleWood)
            b.triangle(SIMD3(0.008, 0.60, 0), SIMD3(0.26, 0.52, 0.02), SIMD3(0.008, 0.40, 0), color: cloth)
            b.triangle(SIMD3(0.008, 0.60, 0), SIMD3(0.008, 0.40, 0), SIMD3(0.26, 0.52, 0.02), color: cloth)
        }

        // 1 · Parasol — pole, canopy cone, and a fringe.
        kind { b in
            b.cylinder(base: .zero, height: 0.70, radius: 0.011, segments: 6, color: paleWood)
            b.cone(base: SIMD3(0, 0.52, 0), height: 0.20, radius: 0.34, segments: 16, color: cloth)
            b.disc(centre: SIMD3(0, 0.515, 0), radius: 0.34, segments: 16,
                   color: cloth2, normal: SIMD3(0, -1, 0))
        }

        // 2 · Pinwheel — a stick and four vanes. It does not spin: the lean
        //     transform is per-instance and the vanes would need their own.
        kind { b in
            b.cylinder(base: .zero, height: 0.55, radius: 0.008, segments: 6, color: paleWood)
            for i in 0..<4 {
                let a = Float(i) / 4 * 2 * .pi
                let dir = SIMD3(cos(a), 0, sin(a))
                let up = SIMD3<Float>(0, 1, 0)
                let hub = SIMD3<Float>(0, 0.53, 0)
                let colours = [cloth, cloth2, plastic, SIMD4<Float>(0.95, 0.78, 0.20, 0.9)]
                b.triangle(hub, hub + dir * 0.13, hub + dir * 0.10 + up * 0.11,
                           color: colours[i])
            }
        }

        // 3 · Lantern — a little glass box on a foot. This one casts light.
        kind { b in
            b.cylinder(base: .zero, height: 0.06, radius: 0.05, segments: 8, color: metal)
            b.box(centre: SIMD3(0, 0.20, 0), size: SIMD3(0.11, 0.20, 0.11),
                  color: SIMD4(0.98, 0.86, 0.58, 0.20))
            b.cone(base: SIMD3(0, 0.30, 0), height: 0.08, radius: 0.09, segments: 8, color: metal)
        }

        // 4 · Pail and spade.
        kind { b in
            b.cylinder(base: .zero, height: 0.20, radius: 0.11, segments: 12, color: plastic, capped: false)
            b.disc(centre: .zero, radius: 0.11, segments: 12, color: plastic, normal: SIMD3(0, -1, 0))
            b.cylinder(base: SIMD3(0.16, 0, 0), height: 0.30, radius: 0.010, segments: 6,
                       color: SIMD4(0.95, 0.78, 0.20, 0.4))
            b.box(centre: SIMD3(0.16, 0.03, 0), size: SIMD3(0.09, 0.06, 0.02),
                  color: SIMD4(0.95, 0.78, 0.20, 0.4))
        }

        // 5 · Toy boat.
        kind { b in
            b.box(centre: SIMD3(0, 0.04, 0), size: SIMD3(0.26, 0.07, 0.11), color: cloth)
            b.cylinder(base: SIMD3(0, 0.07, 0), height: 0.24, radius: 0.006, segments: 5, color: paleWood)
            b.triangle(SIMD3(0.004, 0.30, 0), SIMD3(0.004, 0.10, 0), SIMD3(0.13, 0.11, 0), color: cloth2)
            b.triangle(SIMD3(0.004, 0.30, 0), SIMD3(0.13, 0.11, 0), SIMD3(0.004, 0.10, 0), color: cloth2)
        }

        // 6 · Scallop — a low fluted dome.
        kind { b in
            let segments = 11
            for i in 0..<segments {
                let a0 = Float(i) / Float(segments) * .pi - .pi / 2
                let a1 = Float(i + 1) / Float(segments) * .pi - .pi / 2
                let r: Float = 0.11
                let p0 = SIMD3(cos(a0) * r, 0, sin(a0) * r)
                let p1 = SIMD3(cos(a1) * r, 0, sin(a1) * r)
                let lift = SIMD3<Float>(0, 0.035, 0)
                b.triangle(SIMD3(0, 0.01, 0), p0 + lift * 0.4, p1 + lift * 0.4, color: shell)
            }
        }

        // 7 · Starfish.
        kind { b in
            for i in 0..<5 {
                let a = Float(i) / 5 * 2 * .pi
                let a0 = a - 0.32, a1 = a + 0.32
                b.triangle(SIMD3(0, 0.018, 0),
                           SIMD3(cos(a0) * 0.045, 0.004, sin(a0) * 0.045),
                           SIMD3(cos(a) * 0.13, 0.002, sin(a) * 0.13),
                           color: SIMD4(0.88, 0.52, 0.36, 0.85))
                b.triangle(SIMD3(0, 0.018, 0),
                           SIMD3(cos(a) * 0.13, 0.002, sin(a) * 0.13),
                           SIMD3(cos(a1) * 0.045, 0.004, sin(a1) * 0.045),
                           color: SIMD4(0.88, 0.52, 0.36, 0.85))
            }
        }

        // 8 · Driftwood — a leaning bleached branch.
        kind { b in
            b.cylinder(base: SIMD3(-0.18, 0.02, 0), height: 0.05, radius: 0.035,
                       segments: 7, color: SIMD4(0.78, 0.75, 0.70, 0.95))
            b.box(centre: SIMD3(0, 0.045, 0), size: SIMD3(0.42, 0.055, 0.06),
                  color: SIMD4(0.78, 0.75, 0.70, 0.95))
            b.box(centre: SIMD3(0.14, 0.09, 0.03), size: SIMD3(0.16, 0.035, 0.035),
                  color: SIMD4(0.74, 0.71, 0.66, 0.95))
        }

        // 9 · Kelp — three limp fronds.
        kind { b in
            for i in 0..<3 {
                let a = Float(i) / 3 * 2 * .pi
                let dir = SIMD3(cos(a), 0, sin(a))
                b.quad(SIMD3(0, 0, 0) + dir * 0.02,
                       SIMD3(0, 0, 0) - dir * 0.02,
                       SIMD3(0, 0.24, 0) + dir * 0.09 - dir * 0.02,
                       SIMD3(0, 0.26, 0) + dir * 0.09 + dir * 0.02,
                       color: weed)
            }
        }

        // 10 · Bottle.
        kind { b in
            b.cylinder(base: .zero, height: 0.17, radius: 0.033, segments: 10, color: glass)
            b.cylinder(base: SIMD3(0, 0.17, 0), height: 0.07, radius: 0.014, segments: 8, color: glass)
            b.cylinder(base: SIMD3(0, 0.24, 0), height: 0.02, radius: 0.016, segments: 8, color: wood)
        }

        // 11 · Cairn — four stones, each a little smaller.
        kind { b in
            var y: Float = 0
            let radii: [Float] = [0.085, 0.068, 0.052, 0.036]
            for r in radii {
                let h = r * 1.1
                b.cylinder(base: SIMD3(0, y, 0), height: h, radius: r, segments: 8,
                           color: stone * SIMD4(0.94 + r, 0.94 + r, 0.94 + r, 1))
                y += h * 0.92
            }
        }

        return Built(vertices: builder.vertices, ranges: ranges)
    }
}

// MARK: - Renderer

final class PropRenderer {

    private let vertexBuffer: MTLBuffer
    private let ranges: [Range<Int>]
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int

    private let vertexDescriptor: MTLVertexDescriptor

    init(context: MetalContext) throws {
        let built = PropMeshLibrary.build()
        guard !built.vertices.isEmpty,
              let buffer = context.device.makeBuffer(bytes: built.vertices,
                                                     length: built.vertices.count * MemoryLayout<PropVertex>.stride,
                                                     options: .storageModeShared)
        else { throw MetalSetupError.noDevice }
        buffer.label = "props.vertices"
        vertexBuffer = buffer
        ranges = built.ranges

        instanceCapacity = 128
        guard let instances = context.makeBuffer(length: instanceCapacity * MemoryLayout<SKProp>.stride,
                                                 label: "props.instances")
        else { throw MetalSetupError.noDevice }
        instanceBuffer = instances

        let d = MTLVertexDescriptor()
        d.attributes[0].format = .float3
        d.attributes[0].offset = MemoryLayout<PropVertex>.offset(of: \.position)!
        d.attributes[0].bufferIndex = 0
        d.attributes[1].format = .float3
        d.attributes[1].offset = MemoryLayout<PropVertex>.offset(of: \.normal)!
        d.attributes[1].bufferIndex = 0
        d.attributes[2].format = .float4
        d.attributes[2].offset = MemoryLayout<PropVertex>.offset(of: \.color)!
        d.attributes[2].bufferIndex = 0
        d.layouts[0].stride = MemoryLayout<PropVertex>.stride
        d.layouts[0].stepFunction = .perVertex
        vertexDescriptor = d
    }

    func makePipeline(context: MetalContext,
                      colorFormats: [MTLPixelFormat],
                      depthFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let vfn = context.library.makeFunction(name: "prop_vertex"),
              let ffn = context.library.makeFunction(name: "prop_fragment") else {
            throw MetalSetupError.missingFunction("prop_vertex/prop_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "props"
        descriptor.vertexFunction = vfn
        descriptor.fragmentFunction = ffn
        descriptor.vertexDescriptor = vertexDescriptor
        for (i, format) in colorFormats.enumerated() {
            descriptor.colorAttachments[i]?.pixelFormat = format
        }
        descriptor.depthAttachmentPixelFormat = depthFormat
        return try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    func makeShadowPipeline(context: MetalContext, depthFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let vfn = context.library.makeFunction(name: "prop_shadow_vertex") else {
            throw MetalSetupError.missingFunction("prop_shadow_vertex")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "props.shadow"
        descriptor.vertexFunction = vfn
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.depthAttachmentPixelFormat = depthFormat
        return try context.device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Group props by kind and upload them contiguously, so each kind is one
    /// instanced draw. Twelve draws at worst, and usually two or three.
    private func prepare(_ props: [SKProp]) -> [(range: Range<Int>, first: Int, count: Int)] {
        guard !props.isEmpty else { return [] }

        var buckets = [[SKProp]](repeating: [], count: ranges.count)
        for prop in props {
            let kind = Int(prop.tint.w)
            guard kind >= 0 && kind < buckets.count else { continue }
            buckets[kind].append(prop)
        }

        var flat: [SKProp] = []
        var draws: [(Range<Int>, Int, Int)] = []
        for (kind, bucket) in buckets.enumerated() where !bucket.isEmpty {
            draws.append((ranges[kind], flat.count, bucket.count))
            flat.append(contentsOf: bucket)
        }
        guard !flat.isEmpty else { return [] }

        if flat.count > instanceCapacity {
            instanceCapacity = flat.count * 2
            guard let grown = instanceBuffer.device.makeBuffer(
                length: instanceCapacity * MemoryLayout<SKProp>.stride,
                options: .storageModeShared) else { return [] }
            grown.label = "props.instances"
            instanceBuffer = grown
        }
        flat.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                instanceBuffer.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
        return draws.map { (range: $0.0, first: $0.1, count: $0.2) }
    }

    func encode(encoder: MTLRenderCommandEncoder,
                pipeline: MTLRenderPipelineState,
                props: [SKProp],
                frame: inout SKFrameUniforms,
                look: inout SKLookUniforms,
                skyLUT: MTLTexture,
                shadowMap: MTLTexture) {
        let draws = prepare(props)
        guard !draws.isEmpty else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&look, length: MemoryLayout<SKLookUniforms>.stride, index: 1)
        encoder.setFragmentTexture(skyLUT, index: 0)
        encoder.setFragmentTexture(shadowMap, index: 1)

        for draw in draws {
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: draw.range.lowerBound,
                                   vertexCount: draw.range.count,
                                   instanceCount: draw.count,
                                   baseInstance: draw.first)
        }
    }

    func encodeShadow(encoder: MTLRenderCommandEncoder,
                      pipeline: MTLRenderPipelineState,
                      props: [SKProp],
                      frame: inout SKFrameUniforms) {
        let draws = prepare(props)
        guard !draws.isEmpty else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&frame, length: MemoryLayout<SKFrameUniforms>.stride, index: 2)

        for draw in draws {
            encoder.drawPrimitives(type: .triangle,
                                   vertexStart: draw.range.lowerBound,
                                   vertexCount: draw.range.count,
                                   instanceCount: draw.count,
                                   baseInstance: draw.first)
        }
    }
}
