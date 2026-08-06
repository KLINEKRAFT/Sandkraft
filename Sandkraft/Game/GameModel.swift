//
//  GameModel.swift
//  Sandkraft
//
//  The whole of the game's state, in one observable object.
//
//  Two things are worth calling out.
//
//  First, the pail is not a counter. It is `baselineVolume − currentVolume`,
//  read straight off the GPU metric reduction. There is no bookkeeping to get
//  out of step with the simulation, because there is no bookkeeping: the sand in
//  your pail is, by definition, the sand that is no longer on the beach. The
//  solver conserves volume exactly, so the meter is exactly honest, and an
//  entire category of "I dug a hole and got no sand" bug cannot exist.
//
//  Second, nothing here touches Metal. The model says what happened; the
//  coordinator turns that into brush uniforms and particle emissions. That
//  boundary is what lets the tide state machine be tested without a GPU.
//

import Foundation
import Observation
import simd

// MARK: - Mode and phase

enum GameMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case shore      // free build, no tide
    case tides      // the nine-tide campaign
    case rising     // endless, the water never stops coming

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shore:  return "Open Shore"
        case .tides:  return "Nine Tides"
        case .rising: return "Rising"
        }
    }

    var subtitle: String {
        switch self {
        case .shore:  return "No tide, no clock, every tool."
        case .tides:  return "Nine tides. Each one takes more."
        case .rising: return "The water never stops coming."
        }
    }

    var longDescription: String {
        switch self {
        case .shore:
            return """
            The tide is out and it is staying out. Every tool is unlocked, the sand \
            is unlimited, and the light is yours to set. This is where you find out \
            what the sand will do.
            """
        case .tides:
            return """
            Nine tides, each with a build window and a flood. What is still standing \
            above the high-water line when the water turns is your score. The sun \
            walks down the sky as you go, and the ninth comes in the dark.
            """
        case .rising:
            return """
            One beach, and a tide that keeps climbing. There is no target and no end \
            — only how long you can keep something above the water.
            """
        }
    }
}

enum TidePhase: String, Codable, Sendable {
    case idle          // sandbox: no tide at all
    case briefing      // the card before the clock starts
    case building      // quiet water, the clock running
    case flooding      // the sea coming up
    case reckoning     // results

    var isTimed: Bool { self == .building || self == .flooding }
}

// MARK: - Placed adornment

struct PlacedProp: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: AdornmentID
    var position: SIMD3<Float>
    var yaw: Float
    var scale: Float
    /// The ground height when it was planted. How far the sand has dropped since
    /// is what makes it lean.
    var plantedGroundY: Float
    var leanAxis: SIMD2<Float> = SIMD2(1, 0)
    var leanAngle: Float = 0
    var health: Float = 1
    var toppled: Bool = false
    var age: Float = 0

    var isStanding: Bool { !toppled && leanAngle < 1.05 }
}

// MARK: - Stroke

/// What the input layer hands to the model. Deliberately in world space: the
/// model has no business knowing about touches, pixels or viewports.
struct StrokeSample {
    var world: SIMD3<Float>
    var moisture: Float
    var packing: Float
    var sandDepth: Float
    var bedrock: Float
}

// MARK: - Model

@Observable
@MainActor
final class GameModel {

    // MARK: Session

    private(set) var mode: GameMode = .shore
    private(set) var phase: TidePhase = .idle
    private(set) var tideNumber: Int = 1
    var tide: Tide { Tide.tide(tideNumber) }

    /// Seconds spent in the current phase.
    private(set) var phaseElapsed: Double = 0
    /// Seconds of wave time. Drives the sets, and is what the shader means by
    /// `time`. It keeps running while paused so the sea does not jump on resume.
    private(set) var waveTime: Double = 0

    private(set) var result = TideResult()
    private(set) var grade: Grade?
    private(set) var objectivesMet: [Bool] = []

    var isPaused = false
    private(set) var campaignProgress: Int = 1      // highest tide unlocked

    // MARK: Environment

    var dayFraction: Double = 0.42
    var daySpeed: DaySpeed = .gentle
    var cloudCover: Double = 0.45
    private(set) var atmosphere = AtmosphereState()

    // MARK: Tools

    var selectedToolID: ToolID = .dig
    var selectedMouldID: ToolMouldID = .turret
    var selectedAdornmentID: AdornmentID = .pennant
    var lookID: LookID = .daylight

    /// Multiplier on the tool's own radius. One slider, because two would be one
    /// too many.
    var brushScale: Double = 1.0

    var tool: Tool { Tool.tool(selectedToolID) }
    var mould: Mould { Mould.mould(selectedMouldID) }
    var adornment: Adornment { Adornment.adornment(selectedAdornmentID) }
    var look: Look { Look.look(lookID) }

    var availableTools: [Tool] {
        guard mode == .tides else { return Tool.all }
        return Tool.all.filter { $0.unlockTide <= max(tideNumber, campaignProgress) }
    }

    // MARK: The pail

    /// Cubic metres of sand you are carrying. Derived, never accumulated.
    private(set) var pailVolume: Double = 0
    /// The moisture of what is in it. A running average of what you dug.
    private(set) var pailMoisture: Double = 0.5
    /// How full the pail is against a comfortable working load, for the meter.
    var pailFraction: Double { min(pailVolume / 3.2, 1) }
    var pailIsEmpty: Bool { pailVolume < 0.004 }

    // MARK: Readouts

    private(set) var metrics = SKMetrics()
    /// What is under the cursor right now. Drives the moisture readout, which is
    /// the single most useful number on the screen.
    private(set) var hoverMoisture: Double = 0
    private(set) var hoverPacking: Double = 0
    private(set) var hoverValid = false

    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Smoothed frame time in milliseconds, straight off the renderer. Shown
    /// under Advanced readouts, because "it feels slow" and "it is drawing at
    /// 14 fps" are very different bug reports and only one of them is actionable.
    private(set) var frameMilliseconds: Double = 0

    // MARK: Adornments

    private(set) var props: [PlacedProp] = []
    var lanternCount: Int { props.filter { $0.kind == .lantern && $0.isStanding }.count }

    // MARK: Stroke state

    private(set) var isStroking = false
    private(set) var strokeStart: StrokeSample?
    private(set) var strokeCurrent: StrokeSample?
    private(set) var strokePrevious: StrokeSample?
    /// Sampled once on first contact and held for the whole stroke. Carve, Level
    /// and Wall all work from it, and it is why they feel like tools rather than
    /// brushes.
    private(set) var referenceHeight: Float = 0

    /// Set while the Mould is being held down to fill. Released turns it out.
    private(set) var mouldFillProgress: Double = 0
    private(set) var mouldCharge: (moisture: Double, ready: Bool) = (0, false)

    // MARK: Settings

    var hapticsEnabled = true
    var soundEnabled = true
    var musicEnabled = true
    var reducedMotion = false
    var showAdvancedReadouts = false
    var qualityTier: QualityTier = .medium

    // MARK: Events out
    //
    // The coordinator drains these each frame. An event queue rather than direct
    // calls, so the model stays free of every subsystem it wants to notify.

    enum Effect {
        case digSpray(at: SIMD3<Float>, moisture: Float, volume: Float, toward: SIMD2<Float>)
        case pour(at: SIMD3<Float>, moisture: Float, volume: Float)
        case mouldTurnedOut(at: SIMD3<Float>, moisture: Float)
        case propPlaced(PlacedProp)
        case propToppled(PlacedProp)
        case toolChanged(ToolID)
        case phaseChanged(TidePhase)
        case objectiveMet(Int)
        case undoPerformed
        case collapse(at: SIMD3<Float>, strength: Float)
    }
    private(set) var effects: [Effect] = []

    func drainEffects() -> [Effect] {
        let e = effects
        effects.removeAll(keepingCapacity: true)
        return e
    }

    // MARK: - Lifecycle

    init() {
        atmosphere = Atmosphere.evaluate(dayFraction: dayFraction, cloudCover: cloudCover)
        objectivesMet = Array(repeating: false, count: tide.objectives.count)
    }

    func start(mode newMode: GameMode, tide number: Int = 1) {
        mode = newMode
        tideNumber = min(max(number, 1), Tide.campaign.count)
        result = TideResult()
        grade = nil
        props.removeAll()
        phaseElapsed = 0
        pailVolume = 0
        pailMoisture = 0.5
        objectivesMet = Array(repeating: false, count: tide.objectives.count)

        switch newMode {
        case .shore:
            phase = .idle
            dayFraction = 0.42
            cloudCover = 0.35
        case .tides:
            phase = .briefing
            let t = tide
            dayFraction = Self.dayFraction(forSunElevation: t.sunElevationStart, afternoon: true)
            cloudCover = t.cloudCover * 0.6
            daySpeed = .slow
        case .rising:
            phase = .building
            dayFraction = 0.38
            cloudCover = 0.5
        }
        effects.append(.phaseChanged(phase))
    }

    func beginTide() {
        guard phase == .briefing else { return }
        phase = .building
        phaseElapsed = 0
        effects.append(.phaseChanged(phase))
    }

    func advanceCampaign() {
        campaignProgress = max(campaignProgress, min(tideNumber + 1, Tide.campaign.count))
    }

    // MARK: - Tick

    func update(dt: Double) {
        // The wave clock never stops. Freezing it while paused makes the sea jump
        // half a cycle the moment you resume, which looks like a glitch and is
        // one of the few things a player will never forgive.
        waveTime += dt

        if !isPaused {
            dayFraction += daySpeed.rate * dt
            if dayFraction >= 1 { dayFraction -= 1 }

            if phase.isTimed {
                phaseElapsed += dt
                advancePhaseIfNeeded()
            }
            updateProps(dt: Float(dt))
        }

        atmosphere = Atmosphere.evaluate(dayFraction: dayFraction, cloudCover: cloudCover)
    }

    private func advancePhaseIfNeeded() {
        guard mode == .tides else { return }
        switch phase {
        case .building:
            if phaseElapsed >= tide.buildSeconds {
                phase = .flooding
                phaseElapsed = 0
                effects.append(.phaseChanged(phase))
            }
        case .flooding:
            if phaseElapsed >= tide.floodSeconds {
                phase = .reckoning
                finishTide()
                effects.append(.phaseChanged(phase))
            }
        default:
            break
        }
    }

    private func finishTide() {
        result.adornmentsStanding = props.filter { $0.isStanding }.count
        result.lanternStanding = props.contains { $0.kind == .lantern && $0.isStanding }
        objectivesMet = tide.objectives.map { $0.isMet(result) }
        grade = Grade.evaluate(result, tide: tide, objectivesMet: objectivesMet.filter { $0 }.count)
        if objectivesMet.allSatisfy({ $0 }) || (grade?.points ?? 0) >= 50 {
            advanceCampaign()
        }
    }

    // MARK: - Simulation feedback

    /// Called once a frame with the GPU's latest reduction.
    func ingest(metrics newMetrics: SKMetrics, baselineVolume: Double) {
        metrics = newMetrics

        if baselineVolume > 0 {
            pailVolume = max(baselineVolume - Double(newMetrics.totalVolume), 0)
        }

        result.standing = Double(newMetrics.standingWorth)
        result.packedVolume = Double(newMetrics.packedVolume)
        result.peakAbove = Double(newMetrics.peakHeight)
        // A moat only counts once the sea has actually got into it. A decorative
        // trench above the waterline is a trench.
        if !result.moatFilled, newMetrics.moatVolume > 1.4, currentSeaLevel > tide.lowWater + 0.05 {
            result.moatFilled = true
        }
        if phase == .building || phase == .idle {
            result.peakStanding = max(result.peakStanding, result.standing)
        }

        // Live objective ticks, so the interface can celebrate the moment rather
        // than at the end.
        if phase.isTimed {
            for (i, objective) in tide.objectives.enumerated() where i < objectivesMet.count {
                if !objectivesMet[i], objective.isMet(result) {
                    objectivesMet[i] = true
                    effects.append(.objectiveMet(i))
                }
            }
        }
    }

    func ingest(pick: SKPickResult) {
        hoverValid = pick.point.w > 0.5
        hoverMoisture = Double(pick.sand.x)
        hoverPacking = Double(pick.sand.y)
    }

    func ingest(frameDuration seconds: Double) {
        frameMilliseconds = seconds * 1000
    }

    /// Preformatted here rather than in the view. `String(format:)` is variadic
    /// over CVarArg, and a ternary inside one inside a ViewBuilder is the exact
    /// shape that makes the type-checker give up — twice now, in two different
    /// files. Plain Swift, plain statements, no inference to do.
    var frameTimeDescription: String {
        guard frameMilliseconds > 0.01 else { return "—" }
        let fps = 1000.0 / frameMilliseconds
        return String(format: "%.1f ms · %.0f fps", frameMilliseconds, fps)
    }

    func ingest(canUndo u: Bool, canRedo r: Bool) {
        canUndo = u
        canRedo = r
    }

    // MARK: - The tide

    /// Still-water height right now, before the sets are added.
    var currentSeaLevel: Double {
        switch mode {
        case .shore:
            return -0.34
        case .rising:
            // A slow, relentless climb with a shallow oscillation on top, so
            // there are still moments of respite to work in.
            let minutes = phaseElapsed / 60
            return -0.30 + minutes * 0.085 + sin(phaseElapsed / 26) * 0.05
        case .tides:
            let t = tide
            switch phase {
            case .briefing, .idle:
                return t.lowWater
            case .building:
                // The water creeps up a little even while you build, which is what
                // makes the last thirty seconds of a build window feel like they do.
                let p = min(phaseElapsed / max(t.buildSeconds, 1), 1)
                return t.lowWater + (t.highWater - t.lowWater) * 0.10 * p
            case .flooding, .reckoning:
                let p = min(phaseElapsed / max(t.floodSeconds, 1), 1)
                // Up over the first two thirds, then the turn. A symmetric curve
                // would give the flood no shape at all.
                let rise = p < 0.66 ? smoothstep01(p / 0.66) : 1 - smoothstep01((p - 0.66) / 0.34) * 0.35
                let base = t.lowWater + (t.highWater - t.lowWater) * 0.10
                return base + (t.highWater - base) * rise
            }
        }
    }

    var waveAmplitude: Double {
        switch mode {
        case .shore:  return 0.42
        case .rising: return min(0.55 + phaseElapsed / 240, 1.9)
        case .tides:
            switch phase {
            case .flooding, .reckoning: return tide.amplitude
            case .building: return tide.amplitude * 0.35
            default: return tide.amplitude * 0.28
            }
        }
    }

    var erosionStrength: Double {
        switch mode {
        case .shore:  return 0.55
        case .rising: return 1.0
        case .tides:
            switch phase {
            case .flooding, .reckoning: return 1.0
            case .building: return 0.28
            default: return 0.0
            }
        }
    }

    var highWaterLine: Double {
        switch mode {
        case .shore:  return -0.1
        case .rising: return max(currentSeaLevel, -0.1)
        case .tides:  return tide.highWater
        }
    }

    /// Seconds left in the current phase, or nil where there is no clock.
    var secondsRemaining: Double? {
        switch phase {
        case .building: return max(tide.buildSeconds - phaseElapsed, 0)
        case .flooding: return max(tide.floodSeconds - phaseElapsed, 0)
        default: return nil
        }
    }

    func environment() -> SimulationEnvironment {
        var env = SimulationEnvironment()
        env.time = waveTime
        env.seaBase = currentSeaLevel
        env.waveAmplitude = waveAmplitude
        env.erosion = erosionStrength
        env.sunDrying = Double(atmosphere.dryingRate)
        return env
    }

    // MARK: - Strokes

    func beginStroke(_ sample: StrokeSample) {
        guard phase != .briefing, phase != .reckoning else { return }
        isStroking = true
        strokeStart = sample
        strokeCurrent = sample
        strokePrevious = sample
        referenceHeight = sample.world.y

        if tool.id == .mould {
            mouldFillProgress = 0
            mouldCharge = (0, false)
        } else if tool.id == .place {
            place(at: sample)
            isStroking = false
        }
    }

    func continueStroke(_ sample: StrokeSample) {
        guard isStroking else { return }
        strokePrevious = strokeCurrent
        strokeCurrent = sample

        if tool.id == .mould {
            // Filling. The mould takes what is under it, and what it takes is what
            // will come back out — including how wet it was.
            mouldFillProgress = min(mouldFillProgress + 0.02, 1)
            let blend = 0.12
            mouldCharge.moisture = mouldCharge.moisture * (1 - blend) + Double(sample.moisture) * blend
            mouldCharge.ready = mouldFillProgress > 0.35
        }

        if tool.ledger == .takes {
            // Track what the pail is filling up with, weighted by how much came in.
            let blend = 0.06
            pailMoisture = pailMoisture * (1 - blend) + Double(sample.moisture) * blend
        }
    }

    func endStroke() {
        defer {
            isStroking = false
            strokeStart = nil
            strokeCurrent = nil
            strokePrevious = nil
        }
        guard isStroking else { return }

        if tool.id == .mould, mouldCharge.ready, let sample = strokeCurrent {
            effects.append(.mouldTurnedOut(at: sample.world, moisture: Float(mouldCharge.moisture)))
        }
        mouldFillProgress = 0
        mouldCharge = (0, false)
    }

    func cancelStroke() {
        isStroking = false
        strokeStart = nil
        strokeCurrent = nil
        strokePrevious = nil
        mouldFillProgress = 0
        mouldCharge = (0, false)
    }

    /// The brush the simulation should apply this frame, or nil when nothing is
    /// happening. This is the one place tool semantics turn into solver
    /// parameters, which is exactly one more place than most games manage.
    func currentBrush() -> BrushStroke? {
        guard isStroking, let start = strokeCurrent, let previous = strokePrevious else { return nil }

        let t = tool
        var brush = BrushStroke()
        brush.start = SIMD2(previous.world.x, previous.world.z)
        brush.end = SIMD2(start.world.x, start.world.z)
        brush.radius = Float(t.radius * brushScale)
        brush.strength = Float(t.strength)

        switch t.id {
        case .mould:
            // Holding the mould down scoops rather than pours.
            brush.mode = .scoop
            brush.parameter = 1
        case .place:
            return nil
        default:
            brush.mode = t.mode
            brush.parameter = 1
        }

        if t.samplesReferenceHeight {
            brush.parameter = referenceHeight
        }

        // The pail gate. Pour and Drip cannot conjure sand out of nothing, and the
        // gate is a smooth ramp rather than a switch so the last handful trails
        // off instead of stopping dead.
        if t.ledger == .gives, t.mode != .rampart {
            brush.parameter = Float(min(pailVolume / 0.25, 1))
        }
        if mode == .shore {
            // Unlimited sand on the open shore. It is a sandbox; the argument with
            // the tide is the game, not the argument with the bucket.
            if t.ledger == .gives, t.mode != .rampart { brush.parameter = 1 }
        }

        return brush
    }

    /// The mould stamp to turn out, if the player just released one.
    func mouldStamp(at world: SIMD3<Float>, moisture: Float, rotation: Float) -> MouldStamp {
        let m = mould
        var stamp = MouldStamp()
        stamp.position = SIMD2(world.x, world.z)
        stamp.radius = Float(m.radius * brushScale)
        stamp.height = Float(m.height)
        stamp.detail = Float(m.detail)
        stamp.baseY = world.y
        stamp.rotation = rotation
        stamp.moisture = moisture
        stamp.shapeIndex = m.shapeIndex
        return stamp
    }

    var mouldWillHold: Bool {
        mouldCharge.moisture >= mould.minimumMoisture
    }

    // MARK: - Adornments

    private func place(at sample: StrokeSample) {
        let a = adornment
        let prop = PlacedProp(id: UUID(),
                              kind: a.id,
                              position: sample.world,
                              yaw: Float.random(in: 0..<(2 * .pi)),
                              scale: 1,
                              plantedGroundY: sample.world.y)
        props.append(prop)
        effects.append(.propPlaced(prop))
    }

    func removeLastProp() {
        guard let last = props.popLast() else { return }
        _ = last
    }

    /// Props lean as the sand moves under them and go over when the water
    /// reaches them. Updated on the CPU from the last known ground height, which
    /// the coordinator refreshes from the pick ray as it sweeps.
    private func updateProps(dt: Float) {
        let sea = Float(currentSeaLevel)
        for i in props.indices {
            props[i].age += dt

            if props[i].toppled { continue }

            let drop = props[i].plantedGroundY - props[i].position.y
            if drop > 0.004 {
                // Undermining. The lean grows with how far the ground has gone,
                // and once past about sixty degrees nothing stands back up.
                let target = min(drop * 3.4, 1.6)
                props[i].leanAngle = approach(props[i].leanAngle, target, halfLife: 0.5, dt: dt)
            }

            let submersion = sea - props[i].position.y
            if submersion > 0 {
                let a = Adornment.adornment(props[i].kind)
                let damage = Float(1 - a.resilience) * dt * (0.6 + Float(submersion) * 2.2)
                props[i].health = max(props[i].health - damage, 0)
                props[i].leanAngle += damage * 2.4
            }

            if props[i].health <= 0.02 || props[i].leanAngle > 1.05 {
                props[i].toppled = true
                props[i].leanAngle = 1.45
                effects.append(.propToppled(props[i]))
            }
        }
    }

    /// The coordinator calls this with fresh ground heights sampled off the
    /// simulation, so the lean is driven by real sand rather than a guess.
    func updatePropGround(id: UUID, groundY: Float) {
        guard let index = props.firstIndex(where: { $0.id == id }) else { return }
        props[index].position.y = groundY
    }

    func gpuProps() -> [SKProp] {
        props.map { prop in
            var p = SKProp()
            let a = Adornment.adornment(prop.kind)
            // Toppled props lie on the sand rather than hovering where they stood.
            let sink: Float = prop.toppled ? Float(a.height) * 0.35 : 0
            p.position = SIMD4(prop.position.x, prop.position.y - sink, prop.position.z, prop.scale)
            p.orientation = SIMD4(prop.leanAxis.x, prop.leanAxis.y, prop.leanAngle, prop.yaw)
            p.state = SIMD4(prop.health, 0, prop.toppled ? 1 : 0, prop.age)
            p.tint = SIMD4(1, 1, 1, Float(a.kindIndex))
            return p
        }
    }

    func gpuLanterns() -> [SKPointLight] {
        let night = atmosphere.night
        guard night > 0.05 else { return [] }
        return props
            .filter { $0.kind == .lantern && $0.isStanding }
            .prefix(16)
            .map { prop in
                var light = SKPointLight()
                light.position = SIMD4(prop.position.x, prop.position.y + 0.28, prop.position.z, 3.2)
                light.color = SIMD4(1.0, 0.78, 0.44, 1.35 * night * prop.health)
                return light
            }
    }

    // MARK: - Helpers

    private func smoothstep01(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Find the time of day whose sun elevation matches a tide's brief. Used so a
    /// tide can be authored in degrees — which is how it is thought about — while
    /// the simulation runs on a day fraction.
    static func dayFraction(forSunElevation degrees: Double, afternoon: Bool) -> Double {
        let clamped = min(max(degrees, -14), 65.9)
        let p = asin(clamped / 66) / .pi
        let fraction = afternoon ? (1 - p) : p
        return SunPath.dawn + (SunPath.dusk - SunPath.dawn) * min(max(fraction, 0.02), 0.98)
    }
}
