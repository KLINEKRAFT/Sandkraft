//
//  Tool.swift
//  Sandkraft
//
//  The verbs. Ten of them, which is a lot for a game that wants to feel simple —
//  so the interface never shows a flat list of ten. It shows three families, and
//  the families are not cosmetic: they are the single most useful thing a player
//  can know about this game.
//
//      Material  — changes how much sand exists here
//      Surface   — changes what the sand is *like*
//      Place     — puts something down on top of it
//
//  The difference between Wet and Drip is exactly this and nothing else, and
//  players who never work that out spend the whole campaign confused about why
//  their tower will not grow.
//

import Foundation

// MARK: - Brush mode

/// Mirrors the `mode` switch in `sim_step`. The raw values are a wire format —
/// changing one means changing Sim.metal in the same commit.
enum ToolMode: Int32, Sendable {
    case none    = 0
    case dig     = 1
    case pour    = 2
    case pack    = 3
    case wet     = 4
    case carve   = 5
    case rampart = 6
    case drip    = 7
    case level   = 8
    case smooth  = 9
    case mould   = 10   // handled by the stamp path, never by the brush switch
    case scoop   = 11
}

// MARK: - Brush shape

/// The footprint every stroke tool sweeps along its path.
///
/// This is not a per-tool property and deliberately so: it is a statement about
/// how *you* work, not about what a spade is, and having to set it once per tool
/// would be an interface asking the player to repeat themselves nine times.
///
/// In the solver it is one metric switch — L² gives a disc, L∞ gives a square,
/// and every tool's behaviour is expressed in terms of the resulting falloff, so
/// nothing else has to know. The square is world-axis aligned, which keeps a
/// wall you sweep along X actually straight.
enum BrushShape: String, CaseIterable, Identifiable, Codable, Sendable {
    case round
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .round:  return "Round"
        case .square: return "Square"
        }
    }

    /// What the solver reads out of `stamp3.w`.
    var rawFlag: Float {
        switch self {
        case .round:  return 0
        case .square: return 1
        }
    }
}

// MARK: - Family

enum ToolFamily: String, CaseIterable, Identifiable, Sendable {
    case material
    case surface
    case place

    var id: String { rawValue }

    var title: String {
        switch self {
        case .material: return "Material"
        case .surface:  return "Surface"
        case .place:    return "Place"
        }
    }

    /// Shown once, under the family heading. Short on purpose.
    var caption: String {
        switch self {
        case .material: return "Moves sand. Your pail goes up or down."
        case .surface:  return "Changes what the sand is like. Adds none."
        case .place:    return "Sets something down."
        }
    }
}

// MARK: - Effect on the pail

enum SandLedger: Int, Sendable {
    case takes = -1     // out of the world, into your pail
    case gives = 1      // out of your pail, into the world
    case neither = 0

    var symbol: String {
        switch self {
        case .takes:   return "−"
        case .gives:   return "+"
        case .neither: return "="
        }
    }
}

// MARK: - Tool

struct Tool: Identifiable, Hashable, Sendable {
    let id: ToolID
    let name: String
    let mode: ToolMode
    let family: ToolFamily
    let ledger: SandLedger

    /// Brush radius in metres, before the player's size adjustment.
    let radius: Double
    /// Rate multiplier. Multiplied by dt inside the solver, so it is "per second".
    let strength: Double

    /// The tide at which this tool becomes available in the campaign. Sandbox
    /// modes hand you everything at once.
    let unlockTide: Int

    /// One line. Appears under the tool name in the palette.
    let summary: String
    /// The paragraph. Appears in the tool inspector and in Field Notes.
    let detail: String

    /// Keyboard equivalent on macOS. Also shown as a hint in the palette.
    let shortcut: Character

    /// True when the tool wants a press-and-drag stroke rather than a tap.
    var isStroke: Bool {
        switch mode {
        case .rampart, .carve, .level, .smooth: return true
        default: return true
        }
    }

    /// True when the tool samples a reference height on first contact and holds
    /// it for the rest of the stroke. Carve, Level and Rampart all work this way,
    /// and it is why they feel like tools rather than brushes.
    var samplesReferenceHeight: Bool {
        switch mode {
        case .carve, .level, .rampart: return true
        default: return false
        }
    }
}

enum ToolID: String, CaseIterable, Identifiable, Codable, Sendable {
    case dig, pour, drip, mould, wall
    case pack, wet, carve, level
    case place

    var id: String { rawValue }
}

// MARK: - The palette

extension Tool {
    static let all: [Tool] = [

        // MARK: Material

        Tool(id: .dig, name: "Dig", mode: .dig, family: .material, ledger: .takes,
             radius: 1.50, strength: 0.62, unlockTide: 1,
             summary: "Lifts sand into your pail.",
             detail: """
             Takes sand out of the world — wetness and all — and puts it in your \
             pail. Dig damp sand and the pail stays damp, which matters enormously \
             later. Digging is how you get material, and it is also how you get a \
             moat, and those are the same action seen from two directions.
             """,
             shortcut: "1"),

        Tool(id: .pour, name: "Pour", mode: .pour, family: .material, ledger: .gives,
             radius: 1.30, strength: 0.55, unlockTide: 1,
             summary: "Tips out a heap.",
             detail: """
             Throws real sand, which falls and piles where it lands at whatever \
             angle it can hold. It arrives exactly as wet as your pail says it is. \
             Check the reading before you build anything you care about.
             """,
             shortcut: "2"),

        Tool(id: .drip, name: "Drip", mode: .drip, family: .material, ledger: .gives,
             radius: 0.34, strength: 0.75, unlockTide: 4,
             summary: "Dribbles very wet sand into spires.",
             detail: """
             Takes sand from your pail, adds a splash on the way out, and lets it \
             fall a blob at a time. This grows the knobbled gothic spires that only \
             a beach can make. A dry pail makes a poor spire. Unlike Wet, this one \
             actually builds.
             """,
             shortcut: "3"),

        Tool(id: .mould, name: "Mould", mode: .mould, family: .material, ledger: .gives,
             radius: 1.00, strength: 1.00, unlockTide: 1,
             summary: "Hold to fill, release to turn out.",
             detail: """
             Press and hold on damp sand to scoop the mould full, then aim and \
             release to turn it out. What comes out is exactly as wet as what went \
             in — a mould is a promise between you and the water in the sand, and \
             the sand will show you precisely what it thinks of a broken one.
             """,
             shortcut: "4"),

        Tool(id: .wall, name: "Wall", mode: .rampart, family: .material, ledger: .gives,
             radius: 0.90, strength: 0.90, unlockTide: 2,
             summary: "Drag to raise a ridge.",
             detail: """
             Raises a wall to the height you first pressed at, so it runs level \
             however the ground beneath it rolls. A long packed berm on the seaward \
             side is a seawall, and a seawall is the difference between the third \
             tide and the ninth.
             """,
             shortcut: "5"),

        // MARK: Surface

        Tool(id: .pack, name: "Pack", mode: .pack, family: .surface, ledger: .neither,
             radius: 1.10, strength: 0.55, unlockTide: 1,
             summary: "Drives it down hard.",
             detail: """
             Compaction. Packed sand holds a far steeper face and resists the sea, \
             and — this is the part people miss — packing does not evaporate. Water \
             is what lets you build the face. Packing is what holds it up after the \
             sun has taken the water back.
             """,
             shortcut: "6"),

        Tool(id: .wet, name: "Wet", mode: .wet, family: .surface, ledger: .neither,
             radius: 1.60, strength: 0.60, unlockTide: 1,
             summary: "Raises moisture. Adds no sand.",
             detail: """
             Wets the sand already under the brush so the grains bridge and it can \
             stand steeper. It builds nothing. Damp, not soaked: past a point the \
             water drops touch each other, stop pulling the grains together, and \
             the whole thing runs.
             """,
             shortcut: "7"),

        Tool(id: .carve, name: "Carve", mode: .carve, family: .surface, ledger: .takes,
             radius: 0.55, strength: 0.62, unlockTide: 3,
             summary: "Cuts down to where you first pressed.",
             detail: """
             A blade, not a scoop. Press on the level you want and drag: everything \
             you cross comes down to that height, and the cut edge is packed hard so \
             it stands instead of slumping back in behind the spade. Press on the \
             sand beside a wall and drag through it for a gateway.
             """,
             shortcut: "8"),

        Tool(id: .level, name: "Level", mode: .level, family: .surface, ledger: .neither,
             radius: 1.80, strength: 0.60, unlockTide: 3,
             summary: "Flattens toward your first press.",
             detail: """
             Drives the ground toward the height under your first contact, up or \
             down. Courtyards, terraces, and a flat footing for a tower that would \
             otherwise be built on a slope and know it.
             """,
             shortcut: "9"),

        // MARK: Place

        Tool(id: .place, name: "Place", mode: .none, family: .place, ledger: .neither,
             radius: 0.50, strength: 1.00, unlockTide: 5,
             summary: "Sets an adornment down.",
             detail: """
             Adornments lean as the sand moves under them, and go over when the \
             water reaches them. They are worth nothing at all, and they are the \
             reason anyone remembers a particular castle.
             """,
             shortcut: "0")
    ]

    static func tool(_ id: ToolID) -> Tool {
        // Every ToolID has exactly one entry in `all`; the fallback exists so a
        // future ID added without a definition degrades to Dig rather than
        // trapping in a shipping build.
        all.first { $0.id == id } ?? all[0]
    }

    static func family(_ family: ToolFamily) -> [Tool] {
        all.filter { $0.family == family }
    }
}
