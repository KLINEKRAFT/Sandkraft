//
//  Atmosphere.swift
//  Sandkraft
//
//  The CPU's model of the sky: where the sun is, what colour it arrives, where
//  the moon is, and how thick the air is.
//
//  This duplicates a little of what Sky.metal computes, and that is deliberate.
//  The shader bakes what you *look at*; this produces the handful of scalars the
//  rest of the app needs to make decisions with — the key light colour, whether
//  it is dark enough to light the lanterns, how fast the sand is drying. Reading
//  those back off the GPU would cost a frame of latency to save perhaps twenty
//  lines of arithmetic.
//

import Foundation
import simd

/// The beach faces west. The sun comes up behind the dunes and goes down over
/// the water, which is the entire reason anybody builds here.
enum SunPath {
    static let dawn: Double = 0.235
    static let dusk: Double = 0.795

    /// Elevation and azimuth in degrees for a fraction of the day.
    static func angles(dayFraction t: Double) -> (elevation: Double, azimuth: Double) {
        let p = (t - dawn) / (dusk - dawn)
        return (66 * sin(.pi * p), 272 - 182 * p)
    }

    static func clockText(dayFraction t: Double) -> String {
        let wrapped = ((t.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
        let minutes = Int(wrapped * 1440)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The name of the light, for the interface. Players talk about "golden hour"
    /// long before they talk about "sun elevation 12 degrees".
    static func phaseName(dayFraction t: Double) -> String {
        let elevation = angles(dayFraction: t).elevation
        let rising = t < 0.515
        switch elevation {
        case ..<(-8):  return "deep night"
        case ..<0:     return rising ? "first light" : "dusk"
        case ..<8:     return rising ? "sunrise" : "sunset"
        case ..<20:    return rising ? "early light" : "gold water"
        case ..<42:    return rising ? "morning" : "afternoon"
        case ..<60:    return rising ? "late morning" : "high afternoon"
        default:       return "midday"
        }
    }
}

/// How fast the clock runs. "Held" exists because half the reason to play the
/// sandbox is to work under one particular light for as long as you like.
enum DaySpeed: Int, CaseIterable, Identifiable, Codable, Sendable {
    case held = 0, slow, gentle, brisk

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .held:   return "Held"
        case .slow:   return "Slow"
        case .gentle: return "Gentle"
        case .brisk:  return "Brisk"
        }
    }

    /// Fractions of a day per second.
    var rate: Double {
        switch self {
        case .held:   return 0
        case .slow:   return 1.0 / 1500
        case .gentle: return 1.0 / 720
        case .brisk:  return 1.0 / 300
        }
    }

    var subtitle: String {
        switch self {
        case .held:   return "The light stays where you put it"
        case .slow:   return "25 minutes to a day"
        case .gentle: return "12 minutes to a day"
        case .brisk:  return "5 minutes to a day"
        }
    }
}

struct AtmosphereState {
    var sunDirection = SIMD3<Float>(0, 1, 0)
    var sunColor = SIMD3<Float>(1, 1, 1)
    var sunElevation: Float = 0            // radians
    var moonDirection = SIMD3<Float>(0, 1, 0)
    var moonColor = SIMD3<Float>(0, 0, 0)
    var moonPhase: Float = 0.75
    /// 0 broad daylight … 1 full dark. Everything that needs to know whether it
    /// is night — lanterns, star fade, the printed looks' night plates — reads
    /// this one number so they can never disagree.
    var night: Float = 0
    var fogK: Float = 0.00085
    var exposure: Float = 1
    /// Multiplier on evaporation. Sand dries in the sun and not at night, and a
    /// player who works through dusk should feel the wet sand start to last.
    var dryingRate: Float = 1
}

enum Atmosphere {

    /// Zenith optical depth, per channel, for a clean maritime sky.
    private static let rayleighTau = SIMD3<Float>(0.0469, 0.1085, 0.2648)

    static func evaluate(dayFraction: Double, cloudCover: Double, moonPhase: Double = 0.78) -> AtmosphereState {
        var s = AtmosphereState()

        let (elevationDeg, azimuthDeg) = SunPath.angles(dayFraction: dayFraction)
        let elevation = Float(elevationDeg * .pi / 180)
        let azimuth = Float(azimuthDeg * .pi / 180)
        s.sunElevation = elevation

        let ce = cos(elevation)
        s.sunDirection = normalize(SIMD3(ce * cos(azimuth), sin(elevation), ce * sin(azimuth)))

        // Air mass, Kasten–Young. The correction term is what keeps this finite
        // at and just below the horizon, where 1/sin(elevation) is not.
        let mu = max(Double(sin(elevation)), -0.06)
        let airMass = Float(1.0 / (max(mu, 0) + 0.50572 * pow(max(elevationDeg + 6.07995, 0.2), -1.6364)))

        let turbidity = Float(1.0 + cloudCover * 1.6)
        let mieTau = SIMD3<Float>(repeating: 0.035 * turbidity)
        let transmittance = exp(-(rayleighTau + mieTau) * min(airMass, 38))

        // Below the horizon the sun is gone, but not instantly — civil twilight
        // is about six degrees and is where all the good light lives.
        let horizonFade = smoothstepf(-0.09, 0.05, sin(elevation))
        let intensity: Float = 3.15 * horizonFade * Float(1.0 - cloudCover * 0.45)
        s.sunColor = transmittance * intensity

        s.night = clampf(1 - Atmosphere.luminance(s.sunColor) * 2.2, 0, 1)

        // The moon rides roughly opposite the sun, tilted, so it is up when it is
        // wanted and not a perfect mirror of the sun's arc.
        let moonAngle = Float((dayFraction + 0.5) * 2 * .pi)
        let moonElevation = sin(moonAngle) * 1.05
        let moonAzimuth = moonAngle * 0.6 + 1.1
        let mce = cos(moonElevation)
        s.moonDirection = normalize(SIMD3(mce * cos(moonAzimuth), sin(moonElevation), mce * sin(moonAzimuth)))
        s.moonPhase = Float(moonPhase)

        let moonUp = smoothstepf(-0.05, 0.14, s.moonDirection.y)
        let moonStrength = 0.030 * Float(moonPhase) * moonUp * s.night
        s.moonColor = SIMD3<Float>(0.62, 0.72, 1.00) * moonStrength

        // Thicker air at night. Not physics — it is what a night beach looks like,
        // and it stops the far headlands reading as cardboard cut-outs against
        // black.
        s.fogK = 0.00085 + s.night * 0.0006 + Float(cloudCover) * 0.00022

        // Exposure follows the eye, not the meter: adapt most of the way toward
        // the light level but never all of it, or night stops feeling like night.
        let key = max(Atmosphere.luminance(s.sunColor) + Atmosphere.luminance(s.moonColor) * 8, 0.02)
        s.exposure = clampf(1.05 / pow(key, 0.42), 0.55, 3.4)

        s.dryingRate = clampf(0.12 + 1.35 * smoothstepf(-0.02, 0.45, sin(elevation))
                              * Float(1.0 - cloudCover * 0.4), 0.08, 1.6)

        return s
    }

    static func luminance(_ c: SIMD3<Float>) -> Float {
        dot(c, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }
}
