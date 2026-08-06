//
//  Tide.swift
//  Sandkraft
//
//  Nine tides, each one a build window followed by a flood. The tide does not
//  negotiate: it arrives on schedule, it takes what it can reach, and the score
//  is whatever is still standing when the water turns.
//
//  Objectives are data, not closures. That costs a little ceremony and buys
//  three things worth far more: they are `Codable`, so a save file can carry a
//  partially-completed tide; they render themselves, so the objective text and
//  the objective logic can never disagree; and they are testable without a GPU.
//

import Foundation

// MARK: - Objective

enum ObjectiveKind: Hashable, Codable, Sendable {
    /// Cubic metres of sand standing above the high-water line, weighted by how
    /// well it is packed.
    case standing(Double)
    /// Fraction of your peak Standing that survived the flood.
    case kept(Double)
    /// Metres above the high-water line reached by your highest built point.
    case peakAbove(Double)
    /// Cubic metres of genuinely packed sand built above the pristine profile.
    case packed(Double)
    /// A ditch the sea actually filled, rather than a decorative trench.
    case moatFilled
    /// Adornments still upright at the end of the flood.
    case adornmentsStanding(Int)
    /// One specific adornment still upright. The ninth tide asks for a lantern.
    case lanternStanding

    var text: String {
        switch self {
        case .standing(let v):
            return "Leave \(Int(v)) of Standing above the line"
        case .kept(let f):
            return "Keep \(Self.fractionPhrase(f)) of it through the flood"
        case .peakAbove(let m):
            return String(format: "Stand something %.1f m above high water", m)
        case .packed(let v):
            return "Have \(Int(v)) m³ of properly packed sand"
        case .moatFilled:
            return "Cut a moat the sea actually fills"
        case .adornmentsStanding(let n):
            return "Keep \(n) adornments upright"
        case .lanternStanding:
            return "Still have a lantern lit at the end"
        }
    }

    /// A short form for the compact HUD, where the full sentence will not fit.
    var shortText: String {
        switch self {
        case .standing(let v):          return "\(Int(v)) standing"
        case .kept(let f):              return "\(Int(f * 100))% kept"
        case .peakAbove(let m):         return String(format: "%.1f m high", m)
        case .packed(let v):            return "\(Int(v)) m³ packed"
        case .moatFilled:               return "Moat fills"
        case .adornmentsStanding(let n):return "\(n) upright"
        case .lanternStanding:          return "Lantern lit"
        }
    }

    func isMet(_ r: TideResult) -> Bool {
        switch self {
        case .standing(let v):           return r.standing >= v
        case .kept(let f):               return r.kept >= f
        case .peakAbove(let m):          return r.peakAbove >= m
        case .packed(let v):             return r.packedVolume >= v
        case .moatFilled:                return r.moatFilled
        case .adornmentsStanding(let n): return r.adornmentsStanding >= n
        case .lanternStanding:           return r.lanternStanding
        }
    }

    /// 0…1 progress, for the live objective readout during a tide. Boolean
    /// objectives report 0 or 1 and nothing in between, which is honest.
    func progress(_ r: TideResult) -> Double {
        switch self {
        case .standing(let v):           return min(r.standing / max(v, 1), 1)
        case .kept(let f):               return min(r.kept / max(f, 0.01), 1)
        case .peakAbove(let m):          return min(max(r.peakAbove, 0) / max(m, 0.01), 1)
        case .packed(let v):             return min(r.packedVolume / max(v, 1), 1)
        case .moatFilled:                return r.moatFilled ? 1 : 0
        case .adornmentsStanding(let n): return min(Double(r.adornmentsStanding) / Double(max(n, 1)), 1)
        case .lanternStanding:           return r.lanternStanding ? 1 : 0
        }
    }

    private static func fractionPhrase(_ f: Double) -> String {
        switch f {
        case 0.75...:  return "three quarters"
        case 0.70..<0.75: return "seven tenths"
        case 0.66..<0.70: return "two thirds"
        case 0.60..<0.66: return "three fifths"
        case 0.55..<0.60: return "over half"
        default:       return "half"
        }
    }
}

// MARK: - Tide

struct Tide: Identifiable, Hashable, Sendable {
    let number: Int
    let name: String
    /// One line, shown on the brief card before the tide begins. Kept to a single
    /// sentence — a wall of text before a timer starts is a wall of text nobody
    /// reads.
    let epigraph: String

    /// Still-water height at low and high water, in metres, relative to the
    /// beach datum.
    let lowWater: Double
    let highWater: Double

    /// Seconds of quiet building before the water starts to move.
    let buildSeconds: Double
    /// Seconds of flood, from low water to high water and back to the turn.
    let floodSeconds: Double

    /// Global swell scale. This is the single number that makes the late tides
    /// frightening.
    let amplitude: Double

    /// Sun elevation in degrees at the start and end of the tide. Nine tides walk
    /// the sun down the sky across a campaign, which is doing a lot of quiet
    /// dramatic work for one pair of floats.
    let sunElevationStart: Double
    let sunElevationEnd: Double

    let cloudCover: Double

    let objectives: [ObjectiveKind]

    var id: Int { number }

    /// The score target used for grading. Derived from the first Standing
    /// objective so the two can never drift apart.
    var standingTarget: Double {
        for o in objectives {
            if case .standing(let v) = o { return v }
        }
        return 500
    }

    var totalSeconds: Double { buildSeconds + floodSeconds }
}

// MARK: - The nine

extension Tide {
    static let campaign: [Tide] = [
        Tide(number: 1, name: "First Salt",
             epigraph: "The first tide only wants to know that you are there.",
             lowWater: -0.34, highWater: 0.30,
             buildSeconds: 170, floodSeconds: 62, amplitude: 0.55,
             sunElevationStart: 62, sunElevationEnd: 20.5, cloudCover: 0.55,
             objectives: [.standing(320), .kept(0.75)]),

        Tide(number: 2, name: "The Bucket Turns",
             epigraph: "A mould is a promise between you and the water in the sand.",
             lowWater: -0.32, highWater: 0.44,
             buildSeconds: 170, floodSeconds: 66, amplitude: 0.68,
             sunElevationStart: 52, sunElevationEnd: 17.6, cloudCover: 0.60,
             objectives: [.peakAbove(1.4), .standing(520), .kept(0.70)]),

        Tide(number: 3, name: "A Ditch and a Bank",
             epigraph: "Every ditch is also a bank. Where you put the spoil is the whole of the craft.",
             lowWater: -0.30, highWater: 0.56,
             buildSeconds: 180, floodSeconds: 72, amplitude: 0.80,
             sunElevationStart: 43, sunElevationEnd: 15.0, cloudCover: 0.70,
             objectives: [.moatFilled, .standing(760), .kept(0.70)]),

        Tide(number: 4, name: "The Packing Tide",
             epigraph: "There is a dull, close sound packed sand makes. Work until you hear it everywhere.",
             lowWater: -0.28, highWater: 0.66,
             buildSeconds: 180, floodSeconds: 78, amplitude: 0.94,
             sunElevationStart: 33, sunElevationEnd: 12.7, cloudCover: 0.75,
             objectives: [.packed(45), .standing(1000), .kept(0.66)]),

        Tide(number: 5, name: "Gold Water",
             epigraph: "The sun comes down onto the water and the whole shore turns the colour of a struck coin.",
             lowWater: -0.26, highWater: 0.76,
             buildSeconds: 185, floodSeconds: 84, amplitude: 1.08,
             sunElevationStart: 23, sunElevationEnd: 10.8, cloudCover: 0.85,
             objectives: [.peakAbove(1.9), .standing(1350), .kept(0.66)]),

        Tide(number: 6, name: "The Lanterns",
             epigraph: "Light them anyway. That is the part the sea cannot take back.",
             lowWater: -0.24, highWater: 0.86,
             buildSeconds: 190, floodSeconds: 90, amplitude: 1.22,
             sunElevationStart: 13, sunElevationEnd: 9.4, cloudCover: 0.80,
             objectives: [.adornmentsStanding(4), .standing(1700), .kept(0.60)]),

        Tide(number: 7, name: "Swell from the West",
             epigraph: "The sets come in threes and the third one is a liar. Build for the third one.",
             lowWater: -0.22, highWater: 0.95,
             buildSeconds: 195, floodSeconds: 96, amplitude: 1.48,
             sunElevationStart: 5, sunElevationEnd: 8.4, cloudCover: 1.00,
             objectives: [.standing(1900), .packed(85), .kept(0.60)]),

        Tide(number: 8, name: "Dusk Water",
             epigraph: "Somewhere around here you will stop thinking of it as sand.",
             lowWater: -0.20, highWater: 1.04,
             buildSeconds: 200, floodSeconds: 104, amplitude: 1.66,
             sunElevationStart: -4, sunElevationEnd: 7.6, cloudCover: 0.90,
             objectives: [.standing(2300), .peakAbove(2.4), .kept(0.55)]),

        Tide(number: 9, name: "The Ninth Tide",
             epigraph: "Nine comes in the dark, and it comes all the way. Hold the shape.",
             lowWater: -0.18, highWater: 1.14,
             buildSeconds: 215, floodSeconds: 120, amplitude: 1.85,
             sunElevationStart: -13, sunElevationEnd: 6.8, cloudCover: 0.70,
             objectives: [.standing(2700), .kept(0.50), .lanternStanding])
    ]

    static func tide(_ n: Int) -> Tide {
        campaign.first { $0.number == n } ?? campaign[0]
    }
}

// MARK: - Result

/// Everything the objectives and the grade are computed from. Produced by
/// `Scoring` out of the GPU metrics plus a little CPU bookkeeping.
struct TideResult: Hashable, Codable, Sendable {
    var standing: Double = 0
    var peakStanding: Double = 0
    var packedVolume: Double = 0
    var peakAbove: Double = 0
    var moatFilled: Bool = false
    var adornmentsStanding: Int = 0
    var lanternStanding: Bool = false

    /// Fraction of peak Standing that survived. Defined as 1 before anything has
    /// been built, so an untouched beach does not read as a total loss.
    var kept: Double {
        peakStanding <= 1 ? 1 : min(standing / peakStanding, 1)
    }
}

// MARK: - Grade

struct Grade: Hashable, Sendable {
    let letter: String
    let line: String
    /// 0…100, so the results screen can animate a bar rather than snapping a
    /// letter into place.
    let points: Double

    static func evaluate(_ r: TideResult, tide: Tide, objectivesMet: Int) -> Grade {
        let total = max(tide.objectives.count, 1)

        var p = 0.0
        p += min(r.standing / max(tide.standingTarget, 1), 1.6) * 55
        p += min(r.kept, 1) * 32
        p += Double(objectivesMet) / Double(total) * 13

        switch p {
        case 96...:     return Grade(letter: "S", line: "The shape held. All of it.",                       points: p)
        case 84..<96:   return Grade(letter: "A", line: "The water went back out and found nothing to say.", points: p)
        case 68..<84:   return Grade(letter: "B", line: "It took a corner. It always takes a corner.",       points: p)
        case 50..<68:   return Grade(letter: "C", line: "Standing, mostly. The feet went first.",            points: p)
        case 30..<50:   return Grade(letter: "D", line: "The sea has opinions about your foundations.",      points: p)
        default:        return Grade(letter: "E", line: "It is all still here. It is just flat now.",        points: p)
        }
    }
}
