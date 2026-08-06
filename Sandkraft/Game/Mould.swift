//
//  Mould.swift
//  Sandkraft
//
//  The plastic shapes in the bottom of the beach bag.
//
//  `shapeIndex` indexes `sk_mouldShape()` in Common.h. The two must stay in
//  step: the simulation stamps with that function and the sand shader draws the
//  ghost outline under your cursor from the same call, which is the only reason
//  the preview you line up is exactly what turns out.
//

import Foundation

struct Mould: Identifiable, Hashable, Sendable {
    let id: ToolMouldID
    /// Index into `sk_mouldShape` — a wire format shared with Common.h.
    let shapeIndex: Int32
    let name: String

    /// Footprint radius in metres.
    let radius: Double
    /// Depth of the mould in metres. The turned-out height is this times the
    /// shape's height profile.
    let height: Double
    /// Detail parameter, passed through to the shape function. Only the round
    /// turret reads it (as a crenellation count).
    let detail: Double
    /// The moisture below which this shape will not survive being turned out.
    /// Shown in the interface as a wet/dry gate, because "the tower collapsed and
    /// I do not know why" is the single most common way to lose a player.
    let minimumMoisture: Double

    /// One line, shown in the mould picker.
    let note: String
}

enum ToolMouldID: String, CaseIterable, Identifiable, Codable, Sendable {
    case turret, keep, gatehouse, starFort, ziggurat, spire
    case scallop, fish, crab, starfish

    var id: String { rawValue }
}

extension Mould {
    static let all: [Mould] = [
        Mould(id: .turret,    shapeIndex: 0, radius: 0.95, height: 1.55, detail: 9, minimumMoisture: 0.55,
              note: "Crenellated. The one everybody starts with."),
        Mould(id: .keep,      shapeIndex: 1, radius: 1.05, height: 1.35, detail: 0, minimumMoisture: 0.55,
              note: "Square, with corner towers. Sits well on a levelled pad."),
        Mould(id: .gatehouse, shapeIndex: 2, radius: 1.30, height: 1.25, detail: 0, minimumMoisture: 0.58,
              note: "Two towers and an arch. Line the arch up with a carved road."),
        Mould(id: .starFort,  shapeIndex: 3, radius: 1.35, height: 0.95, detail: 0, minimumMoisture: 0.55,
              note: "Low, wide, and very hard for water to get a grip on."),
        Mould(id: .ziggurat,  shapeIndex: 4, radius: 1.25, height: 1.25, detail: 0, minimumMoisture: 0.50,
              note: "Stepped. Each step is a place a wave has to stop and think."),
        Mould(id: .spire,     shapeIndex: 5, radius: 0.70, height: 2.10, detail: 0, minimumMoisture: 0.68,
              note: "Tall and thin. Needs the wettest sand you have."),
        Mould(id: .scallop,   shapeIndex: 6, radius: 0.95, height: 0.50, detail: 0, minimumMoisture: 0.42,
              note: "A ribbed shell. Flat-topped, so the ribs read."),
        Mould(id: .fish,      shapeIndex: 7, radius: 1.20, height: 0.46, detail: 0, minimumMoisture: 0.42,
              note: "Decorative. Turns out best on packed ground."),
        Mould(id: .crab,      shapeIndex: 8, radius: 1.20, height: 0.42, detail: 0, minimumMoisture: 0.45,
              note: "Claws and legs. Fragile — keep it off the waterline."),
        Mould(id: .starfish,  shapeIndex: 9, radius: 1.20, height: 0.34, detail: 0, minimumMoisture: 0.38,
              note: "Five arms. The most forgiving shape in the bag.")
    ]

    static func mould(_ id: ToolMouldID) -> Mould {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Adornments

struct Adornment: Identifiable, Hashable, Sendable {
    let id: AdornmentID
    /// Index consumed by the props vertex shader, which builds the geometry
    /// procedurally rather than loading a mesh.
    let kindIndex: Int32
    let name: String
    /// Metres tall at scale 1. Drives how easily the sea takes it.
    let height: Double
    /// How much of a soaking it survives. 0 goes over at the first film of water,
    /// 1 stands until the sand under it is gone.
    let resilience: Double

    let note: String
}

enum AdornmentID: String, CaseIterable, Identifiable, Codable, Sendable {
    case pennant, parasol, pinwheel, lantern
    case pailAndSpade, boat, shell, starfish, driftwood, kelp, bottle, cairn

    var id: String { rawValue }
}

extension Adornment {
    static let all: [Adornment] = [
        Adornment(id: .pennant,      kindIndex: 0,  name: "Pennant",       height: 0.62, resilience: 0.35,
                  note: "Leans before it falls. A useful early warning."),
        Adornment(id: .parasol,      kindIndex: 1,  name: "Parasol",       height: 0.70, resilience: 0.28,
                  note: "Top-heavy. Plant it well back."),
        Adornment(id: .pinwheel,     kindIndex: 2,  name: "Pinwheel",      height: 0.55, resilience: 0.30,
                  note: "Turns with the onshore breeze."),
        Adornment(id: .lantern,      kindIndex: 3,  name: "Lantern",       height: 0.40, resilience: 0.55,
                  note: "Lights at dusk. Casts a real pool of light on the sand."),
        Adornment(id: .pailAndSpade, kindIndex: 4,  name: "Pail & spade",  height: 0.32, resilience: 0.62,
                  note: "Low and heavy. Hard to shift."),
        Adornment(id: .boat,         kindIndex: 5,  name: "Toy boat",      height: 0.34, resilience: 0.20,
                  note: "Floats away rather than falling over."),
        Adornment(id: .shell,        kindIndex: 6,  name: "Scallop",       height: 0.14, resilience: 0.75,
                  note: "Barely notices the water."),
        Adornment(id: .starfish,     kindIndex: 7,  name: "Starfish",      height: 0.10, resilience: 0.78,
                  note: "Lies flat. Practically part of the beach."),
        Adornment(id: .driftwood,    kindIndex: 8,  name: "Driftwood",     height: 0.22, resilience: 0.68,
                  note: "Long and low. Doubles as a small groyne."),
        Adornment(id: .kelp,         kindIndex: 9,  name: "Kelp",          height: 0.30, resilience: 0.72,
                  note: "Wet already. Nothing to lose."),
        Adornment(id: .bottle,       kindIndex: 10, name: "Bottle",        height: 0.26, resilience: 0.45,
                  note: "Rolls when undermined."),
        Adornment(id: .cairn,        kindIndex: 11, name: "Cairn",         height: 0.46, resilience: 0.50,
                  note: "Stacked stones. Topples one course at a time.")
    ]

    static func adornment(_ id: AdornmentID) -> Adornment {
        all.first { $0.id == id } ?? all[0]
    }
}
