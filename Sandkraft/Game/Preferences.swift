//
//  Preferences.swift
//  Sandkraft
//
//  What survives the app being quit.
//
//  Until now, nothing did. Every launch reset the quality tier, the look, the
//  brush, the sound switches — and the campaign, so a player who reached tide
//  five came back to tide one.
//
//  The mechanism is deliberately small. `StoredPreferences` is a value type;
//  `GameModel` exposes the current one as a computed property; `RootView`
//  watches that property and writes it back when it changes. That is the whole
//  of it — no `didSet` on observed properties, no property wrapper, and no
//  storage vocabulary anywhere inside the model.
//

import Foundation

// MARK: - The value

/// Everything the player chose that should still be true tomorrow.
///
/// `dayFraction` is deliberately absent. The time of day is where you are in a
/// session, not a preference — restoring it would mean starting every launch at
/// whatever hour you happened to quit, which is a stranger thing to inherit than
/// it first sounds.
struct StoredPreferences: Equatable, Sendable {
    /// `nil` means the player has never overridden the automatic choice, which
    /// is the only case in which the device's own recommendation should win.
    var qualityTier: QualityTier?

    var lookID: LookID = .daylight
    var brushScale: Double = 1.0
    var brushShape: BrushShape = .round

    var hapticsEnabled: Bool = true
    var soundEnabled: Bool = true
    var musicEnabled: Bool = true
    var reducedMotion: Bool = false
    var showAdvancedReadouts: Bool = false

    var daySpeed: DaySpeed = .gentle
    var cloudCover: Double = 0.45

    /// Drafting. Both off by default — a game about a material that slumps
    /// should not open with a grid switched on.
    var snapToGrid: Bool = false
    var snapSpacing: Double = 0.5
    var straightStrokes: Bool = false

    /// Which way a drag turns the world. Not a thing with a right answer, and
    /// emphatically a thing to remember once somebody has decided.
    var invertOrbitX: Bool = false
    var invertOrbitY: Bool = false
    var invertZoom: Bool = false

    /// How big the sea is, over everything the tide already asks for.
    var surf: Double = 0.85

    var campaignProgress: Int = 1
}

// MARK: - The store

enum Preferences {
    private static var store: UserDefaults { .standard }

    /// One key per preference rather than a single `Codable` blob.
    ///
    /// A blob decodes all-or-nothing: the synthesised `init(from:)` throws on a
    /// missing key rather than falling back to the property's default, so the
    /// day a tenth preference is added, every existing player silently loses the
    /// nine they had already set. Individual keys fall back individually, which
    /// is the behaviour actually wanted and is what `UserDefaults` is for.
    private enum Key {
        static let quality = "sk.quality"
        static let look = "sk.look"
        static let brushScale = "sk.brushScale"
        static let brushShape = "sk.brushShape"
        static let haptics = "sk.haptics"
        static let sound = "sk.sound"
        static let music = "sk.music"
        static let reducedMotion = "sk.reducedMotion"
        static let advanced = "sk.advancedReadouts"
        static let daySpeed = "sk.daySpeed"
        static let cloud = "sk.cloudCover"
        static let campaign = "sk.campaignProgress"
        static let snapToGrid = "sk.snapToGrid"
        static let snapSpacing = "sk.snapSpacing"
        static let straightStrokes = "sk.straightStrokes"
        static let invertOrbitX = "sk.invertOrbitX"
        static let invertOrbitY = "sk.invertOrbitY"
        static let invertZoom = "sk.invertZoom"
        static let surf = "sk.surf"
    }

    // `object(forKey:)` rather than `double(forKey:)` or `bool(forKey:)`,
    // because those return 0 and false for a key that was never written — which
    // is indistinguishable from a player who genuinely chose 0 and false, and
    // would quietly turn every default off on first run.

    private static func storedInt(_ key: String) -> Int? {
        store.object(forKey: key) as? Int
    }

    private static func storedDouble(_ key: String, _ fallback: Double) -> Double {
        store.object(forKey: key) as? Double ?? fallback
    }

    private static func storedBool(_ key: String, _ fallback: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    static func load() -> StoredPreferences {
        var p = StoredPreferences()

        if let raw = storedInt(Key.quality) {
            p.qualityTier = QualityTier(rawValue: raw)
        }
        if let raw = storedInt(Key.look),
           let id = LookID(rawValue: Int32(truncatingIfNeeded: raw)) {
            p.lookID = id
        }
        if let raw = storedInt(Key.daySpeed), let speed = DaySpeed(rawValue: raw) {
            p.daySpeed = speed
        }
        if let raw = store.string(forKey: Key.brushShape),
           let shape = BrushShape(rawValue: raw) {
            p.brushShape = shape
        }

        p.brushScale = storedDouble(Key.brushScale, p.brushScale)
        p.cloudCover = storedDouble(Key.cloud, p.cloudCover)
        p.hapticsEnabled = storedBool(Key.haptics, p.hapticsEnabled)
        p.soundEnabled = storedBool(Key.sound, p.soundEnabled)
        p.musicEnabled = storedBool(Key.music, p.musicEnabled)
        p.reducedMotion = storedBool(Key.reducedMotion, p.reducedMotion)
        p.showAdvancedReadouts = storedBool(Key.advanced, p.showAdvancedReadouts)
        p.campaignProgress = storedInt(Key.campaign) ?? p.campaignProgress

        p.snapToGrid = storedBool(Key.snapToGrid, p.snapToGrid)
        p.snapSpacing = storedDouble(Key.snapSpacing, p.snapSpacing)
        p.straightStrokes = storedBool(Key.straightStrokes, p.straightStrokes)
        p.invertOrbitX = storedBool(Key.invertOrbitX, p.invertOrbitX)
        p.invertOrbitY = storedBool(Key.invertOrbitY, p.invertOrbitY)
        p.invertZoom = storedBool(Key.invertZoom, p.invertZoom)
        p.surf = storedDouble(Key.surf, p.surf)

        // A stored value is not automatically a sane one. The defaults file is
        // editable, and a future build can narrow a range underneath a number
        // that was perfectly legal when it was written. Clamping on the way in
        // means the rest of the app never has to wonder.
        p.brushScale = min(max(p.brushScale, 0.45), 2.0)
        p.cloudCover = min(max(p.cloudCover, 0.0), 1.0)
        p.campaignProgress = min(max(p.campaignProgress, 1), Tide.campaign.count)
        // A pitch of zero would divide by nothing and put the whole beach on one
        // texel; a pitch bigger than the brush is a grid you cannot draw on.
        p.snapSpacing = min(max(p.snapSpacing, 0.1), 2.0)
        p.surf = min(max(p.surf, 0.0), 1.5)

        return p
    }

    static func save(_ p: StoredPreferences) {
        // Only written once the player has a tier at all. Everything else always
        // has a value worth keeping.
        if let tier = p.qualityTier {
            store.set(tier.rawValue, forKey: Key.quality)
        }
        store.set(Int(p.lookID.rawValue), forKey: Key.look)
        store.set(p.daySpeed.rawValue, forKey: Key.daySpeed)
        store.set(p.brushShape.rawValue, forKey: Key.brushShape)
        store.set(p.brushScale, forKey: Key.brushScale)
        store.set(p.cloudCover, forKey: Key.cloud)
        store.set(p.hapticsEnabled, forKey: Key.haptics)
        store.set(p.soundEnabled, forKey: Key.sound)
        store.set(p.musicEnabled, forKey: Key.music)
        store.set(p.reducedMotion, forKey: Key.reducedMotion)
        store.set(p.showAdvancedReadouts, forKey: Key.advanced)
        store.set(p.campaignProgress, forKey: Key.campaign)
        store.set(p.snapToGrid, forKey: Key.snapToGrid)
        store.set(p.snapSpacing, forKey: Key.snapSpacing)
        store.set(p.straightStrokes, forKey: Key.straightStrokes)
        store.set(p.invertOrbitX, forKey: Key.invertOrbitX)
        store.set(p.invertOrbitY, forKey: Key.invertOrbitY)
        store.set(p.invertZoom, forKey: Key.invertZoom)
        store.set(p.surf, forKey: Key.surf)
    }

    /// Back to a clean slate, campaign included. Wired to a button in Settings
    /// that asks first, because this throws away progress.
    static func reset() {
        let keys = [Key.quality, Key.look, Key.brushScale, Key.brushShape,
                    Key.haptics, Key.sound, Key.music, Key.reducedMotion,
                    Key.advanced, Key.daySpeed, Key.cloud, Key.campaign,
                    Key.snapToGrid, Key.snapSpacing, Key.straightStrokes,
                    Key.invertOrbitX, Key.invertOrbitY, Key.invertZoom, Key.surf]
        for key in keys {
            store.removeObject(forKey: key)
        }
    }
}
