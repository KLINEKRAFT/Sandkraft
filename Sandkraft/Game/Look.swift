//
//  Look.swift
//  Sandkraft
//
//  Nine looks. The same simulation, the same light, the same water — rendered
//  nine ways.
//
//  The important architectural decision here is that a look is *data*, not a
//  shader variant. Nine copies of the terrain shader would be nine places to fix
//  every bug. Instead each look is a small set of parameters, the shaders branch
//  on `look` exactly once each — in the surface-styling function, where the
//  branch is genuinely different work rather than different constants — and
//  everything else reads the profile.
//

import Foundation
import simd

enum LookID: Int32, CaseIterable, Identifiable, Codable, Sendable {
    case daylight   = 0
    case posterPaint = 1
    case screenPrint = 2
    case survey      = 3
    case felt        = 4
    case shallows    = 5
    case enamel      = 6
    case woodblock   = 7
    case offSeason   = 8

    var id: Int32 { rawValue }
}

/// How a look treats light. This is the one thing the shaders branch on.
enum LightTreatment: Int32, Sendable {
    /// Continuous physically-based shading.
    case continuous = 0
    /// Quantised into soft bands.
    case banded = 1
    /// Separated into flat inks with a rotated dot screen between each pair.
    case separated = 2
    /// Mapped to contour intervals over a flat base — light becomes elevation.
    case contoured = 3
}

struct Look: Identifiable, Hashable, Sendable {
    let id: LookID
    let name: String
    /// Six words at most. Sits under the name in the picker.
    let note: String

    let treatment: LightTreatment

    // MARK: Surface

    /// Multiplied into the dry sand albedo.
    let sandTint: SIMD3<Float>
    /// Multiplied into the wet sand albedo. Wet sand is darker and more saturated
    /// in life; some looks exaggerate that and some flatten it.
    let wetTint: SIMD3<Float>
    let waterTint: SIMD3<Float>
    let foamTint: SIMD3<Float>

    /// Oren–Nayar roughness for the sand. Higher reads chalkier.
    let sandRoughness: Float
    /// How much the wet-sand specular sheet is allowed to show.
    let wetSpecular: Float
    /// Strength of the procedural grain/ripple detail normal.
    let microDetail: Float

    // MARK: Bands and inks

    /// Number of light steps for `.banded` and `.separated`.
    let bandCount: Float
    /// Softness of each band edge. A hard floor() crawls as the sun moves.
    let bandSoftness: Float
    /// Screen angle in radians and cell size in pixels, for `.separated`.
    let screenAngle: Float
    let screenScale: Float

    // MARK: Post

    let exposure: Float
    let contrast: Float
    let saturation: Float
    let bloom: Float
    let vignette: Float
    let grain: Float
    /// Lateral colour fringing. Small values sell "printed"; anything visible
    /// sells "broken".
    let chromatic: Float

    /// Ink outline weight for the looks that draw one. 0 disables the pass.
    let outline: Float

    /// Contour interval in metres for `.survey`. Ignored elsewhere.
    let contourInterval: Float
}

extension Look {
    static let all: [Look] = [

        Look(id: .daylight, name: "Daylight", note: "the shore as it is",
             treatment: .continuous,
             sandTint: SIMD3(1.00, 1.00, 1.00), wetTint: SIMD3(0.96, 0.95, 0.94),
             waterTint: SIMD3(1.00, 1.00, 1.00), foamTint: SIMD3(1.00, 1.00, 1.00),
             sandRoughness: 0.92, wetSpecular: 1.00, microDetail: 1.00,
             bandCount: 0, bandSoftness: 0, screenAngle: 0, screenScale: 0,
             exposure: 1.00, contrast: 1.00, saturation: 1.00,
             bloom: 0.35, vignette: 0.22, grain: 0.012, chromatic: 0.0,
             outline: 0.0, contourInterval: 0),

        Look(id: .posterPaint, name: "Poster Paint", note: "painted, inked, cosy",
             treatment: .banded,
             sandTint: SIMD3(1.10, 1.02, 0.86), wetTint: SIMD3(0.82, 0.78, 0.76),
             waterTint: SIMD3(0.78, 1.05, 1.10), foamTint: SIMD3(1.00, 1.00, 1.00),
             sandRoughness: 1.00, wetSpecular: 0.45, microDetail: 0.35,
             bandCount: 5, bandSoftness: 0.10, screenAngle: 0, screenScale: 0,
             exposure: 1.05, contrast: 1.12, saturation: 1.28,
             bloom: 0.20, vignette: 0.18, grain: 0.010, chromatic: 0.0,
             outline: 0.85, contourInterval: 0),

        Look(id: .screenPrint, name: "Screen Print", note: "five inks and a dot screen",
             treatment: .separated,
             sandTint: SIMD3(1.00, 1.00, 1.00), wetTint: SIMD3(1.00, 1.00, 1.00),
             waterTint: SIMD3(1.00, 1.00, 1.00), foamTint: SIMD3(1.00, 1.00, 1.00),
             sandRoughness: 1.00, wetSpecular: 0.20, microDetail: 0.15,
             bandCount: 5, bandSoftness: 0.0, screenAngle: 0.4014, screenScale: 3.4,
             exposure: 1.00, contrast: 1.00, saturation: 1.00,
             bloom: 0.06, vignette: 0.30, grain: 0.020, chromatic: 0.0,
             outline: 0.0, contourInterval: 0),

        Look(id: .survey, name: "Survey", note: "a chart of the sand",
             treatment: .contoured,
             sandTint: SIMD3(1.02, 0.99, 0.92), wetTint: SIMD3(0.86, 0.92, 0.98),
             waterTint: SIMD3(0.80, 0.90, 1.00), foamTint: SIMD3(1.00, 1.00, 1.00),
             sandRoughness: 1.00, wetSpecular: 0.10, microDetail: 0.0,
             bandCount: 0, bandSoftness: 0, screenAngle: 0, screenScale: 0,
             exposure: 1.02, contrast: 1.05, saturation: 0.55,
             bloom: 0.0, vignette: 0.12, grain: 0.028, chromatic: 0.0,
             outline: 0.55, contourInterval: 0.15),

        Look(id: .felt, name: "Felt", note: "a craft-fair diorama",
             treatment: .banded,
             sandTint: SIMD3(1.06, 0.98, 0.88), wetTint: SIMD3(0.80, 0.76, 0.72),
             waterTint: SIMD3(0.74, 0.94, 0.98), foamTint: SIMD3(0.98, 0.98, 0.96),
             sandRoughness: 1.00, wetSpecular: 0.10, microDetail: 0.85,
             bandCount: 4, bandSoftness: 0.22, screenAngle: 0, screenScale: 0,
             exposure: 0.98, contrast: 0.92, saturation: 0.94,
             bloom: 0.14, vignette: 0.26, grain: 0.055, chromatic: 0.0,
             outline: 0.30, contourInterval: 0),

        Look(id: .shallows, name: "Shallows", note: "a foot under clear water",
             treatment: .continuous,
             sandTint: SIMD3(0.86, 0.98, 1.02), wetTint: SIMD3(0.78, 0.94, 1.02),
             waterTint: SIMD3(0.72, 1.02, 1.08), foamTint: SIMD3(1.00, 1.00, 1.00),
             sandRoughness: 0.80, wetSpecular: 1.25, microDetail: 1.20,
             bandCount: 0, bandSoftness: 0, screenAngle: 0, screenScale: 0,
             exposure: 1.06, contrast: 1.02, saturation: 1.14,
             bloom: 0.55, vignette: 0.30, grain: 0.008, chromatic: 0.0018,
             outline: 0.0, contourInterval: 0),

        Look(id: .enamel, name: "Enamel", note: "on pressed tin",
             treatment: .banded,
             sandTint: SIMD3(1.14, 1.04, 0.82), wetTint: SIMD3(0.74, 0.74, 0.78),
             waterTint: SIMD3(0.66, 1.02, 1.14), foamTint: SIMD3(1.00, 1.00, 1.00),
             sandRoughness: 0.55, wetSpecular: 1.60, microDetail: 0.10,
             bandCount: 3, bandSoftness: 0.05, screenAngle: 0, screenScale: 0,
             exposure: 1.08, contrast: 1.30, saturation: 1.40,
             bloom: 0.42, vignette: 0.14, grain: 0.006, chromatic: 0.0,
             outline: 1.00, contourInterval: 0),

        Look(id: .woodblock, name: "Woodblock", note: "ragged key plate",
             treatment: .separated,
             sandTint: SIMD3(1.04, 0.98, 0.90), wetTint: SIMD3(0.72, 0.72, 0.74),
             waterTint: SIMD3(0.82, 0.92, 0.96), foamTint: SIMD3(1.00, 1.00, 0.98),
             sandRoughness: 1.00, wetSpecular: 0.16, microDetail: 0.30,
             bandCount: 4, bandSoftness: 0.0, screenAngle: 0.7854, screenScale: 5.2,
             exposure: 0.96, contrast: 1.16, saturation: 0.82,
             bloom: 0.04, vignette: 0.34, grain: 0.075, chromatic: 0.0,
             outline: 1.20, contourInterval: 0),

        Look(id: .offSeason, name: "Off-Season", note: "the beach in February",
             treatment: .continuous,
             sandTint: SIMD3(0.90, 0.92, 0.96), wetTint: SIMD3(0.72, 0.76, 0.82),
             waterTint: SIMD3(0.84, 0.90, 0.94), foamTint: SIMD3(0.96, 0.97, 1.00),
             sandRoughness: 0.98, wetSpecular: 0.85, microDetail: 1.10,
             bandCount: 0, bandSoftness: 0, screenAngle: 0, screenScale: 0,
             exposure: 0.92, contrast: 0.94, saturation: 0.58,
             bloom: 0.22, vignette: 0.34, grain: 0.026, chromatic: 0.0,
             outline: 0.0, contourInterval: 0)
    ]

    static func look(_ id: LookID) -> Look {
        all.first { $0.id == id } ?? all[0]
    }
}
