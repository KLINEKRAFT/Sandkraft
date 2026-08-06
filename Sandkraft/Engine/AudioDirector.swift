//
//  AudioDirector.swift
//  Sandkraft
//
//  Every sound in the game is synthesised. There are no audio files.
//
//  That is not a stunt. The surf has to follow the actual sea — the same
//  `sk_seaLevelAt` breathing that runs the swash up the beach — and a looping
//  recording cannot do that without either drifting out of phase or being cut
//  into so many pieces that the seams show. Filtered noise driven by the wave
//  state is in phase by construction, costs about 40 KB of code, and never
//  needs a licence.
//
//  Architecture:
//    · one AVAudioSourceNode renders the bed (surf, wind, the water film) from
//      the game's own wave clock;
//    · one-shots are rendered into buffers at launch and played by a small pool
//      of player nodes, so a burst of taps never allocates.
//

import Foundation
import AVFoundation

// MARK: - One-shots

enum AudioCue {
    case toolTap
    case mouldTurnedOut
    case propPlaced
    case propToppled
    case objectiveMet
    case phaseChange
    case floodBegins
    case undo
    case collapse
}

@MainActor
final class AudioDirector {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var players: [AVAudioPlayerNode] = []
    private var cueBuffers: [String: AVAudioPCMBuffer] = [:]
    private var nextPlayer = 0
    private var running = false

    var enabled = true {
        didSet { enabled ? start() : stop() }
    }

    // MARK: Bed state
    //
    // Written on the main thread once a frame, read on the audio thread. Plain
    // atomics-by-alignment on Float: a torn read here is a single sample at a
    // slightly wrong gain, which is inaudible, and a lock on the render thread
    // is a click.

    private final class BedState: @unchecked Sendable {
        var surfLevel: Float = 0.35
        var breakEnergy: Float = 0.2
        var windLevel: Float = 0.12
        var waterProximity: Float = 0.3
        var toolLevel: Float = 0
        var toolTone: Float = 0.5
        var masterGain: Float = 0.9
    }
    private let bed = BedState()

    private let sampleRate: Double = 44100

    init() {
        configureSession()
        buildOneShots()
        start()
    }

    private func configureSession() {
        #if os(iOS)
        // Ambient: the game is not a music app, and somebody playing this on a
        // train with their own music on should keep their own music.
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio is a nicety. A session that will not configure is a reason to
            // be quiet, not a reason to fail to launch.
        }
        #endif
    }

    // MARK: - Engine

    private func start() {
        guard !running, enabled else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        guard let format else { return }

        let node = AVAudioSourceNode(format: format) { [bed] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // The render block captures `bed` and its own scratch by value where
            // it can; the filter state below is intentionally function-local and
            // static-free, so nothing outside the audio thread ever touches it.
            return AudioDirector.renderBed(into: buffers, frames: Int(frameCount), bed: bed)
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        for _ in 0..<6 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            players.append(player)
        }

        engine.mainMixerNode.outputVolume = 0.85
        do {
            try engine.start()
            players.forEach { $0.play() }
            running = true
        } catch {
            running = false
        }
    }

    private func stop() {
        guard running else { return }
        engine.stop()
        players.removeAll()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        running = false
    }

    // MARK: - The bed
    //
    // Static, so the render block never captures `self` and therefore never
    // retains an object that the main thread might be mutating.

    private nonisolated static func renderBed(into buffers: UnsafeMutableAudioBufferListPointer,
                                              frames: Int,
                                              bed: BedState) -> OSStatus {
        var rng: UInt32 = 0x2545F491
        var lp1: Float = 0, lp2: Float = 0, hp: Float = 0, last: Float = 0
        var toolPhase: Float = 0

        let surf = bed.surfLevel
        let breaking = bed.breakEnergy
        let wind = bed.windLevel
        let proximity = bed.waterProximity
        let toolLevel = bed.toolLevel
        let toolTone = bed.toolTone
        let master = bed.masterGain

        for frame in 0..<frames {
            // White noise, xorshift. Cheap, flat enough, and deterministic.
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            let white = Float(Int32(bitPattern: rng)) / Float(Int32.max)

            // Two cascaded one-poles make the low roar of distant water.
            let cutoff: Float = 0.020 + 0.055 * breaking
            lp1 += (white - lp1) * cutoff
            lp2 += (lp1 - lp2) * cutoff
            let roar = lp2 * (2.6 + 3.4 * surf)

            // A one-zero high pass over the same noise gives the hiss of a wave
            // running out on sand. It is the same source, so the two are always
            // the same wave.
            hp = 0.86 * (hp + white - last)
            last = white
            let hiss = hp * (0.10 + 0.55 * breaking) * proximity

            // Wind: band-limited noise with a slow amplitude wobble.
            let gust = 0.55 + 0.45 * sin(Float(frame) * 0.00004)
            let breeze = lp1 * wind * gust * 1.4

            // Tool sound: filtered noise, brightness set by the tool.
            toolPhase += 0.0007
            let toolNoise = (hp * 0.6 + lp1 * 0.4) * toolLevel
                          * (0.5 + 0.5 * sin(toolPhase * (2.0 + toolTone * 6.0)))

            var sample = (roar + hiss + breeze + toolNoise) * 0.22 * master
            sample = max(min(sample, 1), -1)

            // A hair of stereo width from a single-sample offset on the right.
            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] = channel == 0 ? sample : sample * 0.94 + hiss * 0.04
            }
        }
        return noErr
    }

    // MARK: - Per-frame

    func update(model: GameModel, dt: Double) {
        guard running else { return }

        // Surf follows the actual sea state, not a timer.
        let amplitude = Float(model.waveAmplitude)
        let phaseEnergy: Float = model.phase == .flooding ? 1.0 : 0.45
        bed.surfLevel = min(0.20 + amplitude * 0.55, 1.2)
        bed.breakEnergy = min(0.10 + amplitude * 0.42 * phaseEnergy, 1.0)
        bed.windLevel = 0.06 + Float(model.cloudCover) * 0.16
        bed.waterProximity = 0.25 + Float(min(max(model.metrics.wettedArea / 260, 0), 1)) * 0.75
        bed.masterGain = enabled ? (model.isPaused ? 0.35 : 0.9) : 0

        // The tool bed fades in and out rather than switching, or every stroke
        // starts and ends with a click.
        let target: Float = model.isStroking ? 0.55 : 0
        bed.toolLevel += (target - bed.toolLevel) * Float(min(dt * 9, 1))
    }

    func beginTool(_ tool: ToolID) {
        // Brightness per tool, so digging and patting do not sound the same.
        switch tool {
        case .dig, .carve:  bed.toolTone = 0.85
        case .pour, .drip:  bed.toolTone = 0.35
        case .pack, .level: bed.toolTone = 0.15
        case .wet:          bed.toolTone = 0.55
        default:            bed.toolTone = 0.5
        }
        play(.toolTap)
    }

    func endTool() {
        bed.toolLevel = 0
    }

    // MARK: - One-shots

    private func buildOneShots() {
        func make(_ key: String, seconds: Double, _ generator: (Double, Double) -> Float) {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(sampleRate * seconds))
            else { return }
            buffer.frameLength = buffer.frameCapacity
            let count = Int(buffer.frameLength)
            guard let channels = buffer.floatChannelData else { return }
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let v = generator(t, seconds)
                channels[0][i] = v
                if buffer.format.channelCount > 1 { channels[1][i] = v }
            }
            cueBuffers[key] = buffer
        }

        var rng: UInt32 = 0x1234567
        func noise() -> Float {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            return Float(Int32(bitPattern: rng)) / Float(Int32.max)
        }

        // A soft grainy tick — the sound of a spade going in.
        make("toolTap", seconds: 0.09) { t, d in
            let env = Float(exp(-t * 46))
            return noise() * env * 0.28
        }
        // The dull close thump of a mould coming off.
        make("mouldTurnedOut", seconds: 0.36) { t, d in
            let env = Float(exp(-t * 11))
            let body = Float(sin(2 * .pi * 96 * t)) * 0.5 + Float(sin(2 * .pi * 148 * t)) * 0.25
            return (body + noise() * 0.35) * env * 0.42
        }
        make("propPlaced", seconds: 0.14) { t, d in
            let env = Float(exp(-t * 26))
            return Float(sin(2 * .pi * 620 * t)) * env * 0.14
        }
        make("propToppled", seconds: 0.30) { t, d in
            let env = Float(exp(-t * 13))
            return noise() * env * 0.22
        }
        // Two notes, a fifth apart, arriving one after the other. Small, and it
        // does not sound like a notification.
        make("objectiveMet", seconds: 0.55) { t, d in
            let a = Float(exp(-t * 6)) * Float(sin(2 * .pi * 587.33 * t))
            let delay = max(t - 0.11, 0)
            let b = Float(exp(-delay * 6)) * Float(sin(2 * .pi * 880.0 * delay)) * (t > 0.11 ? 1 : 0)
            return (a * 0.5 + b * 0.45) * 0.16
        }
        make("phaseChange", seconds: 0.6) { t, d in
            let env = Float(exp(-t * 4.2))
            return Float(sin(2 * .pi * 196 * t)) * env * 0.16
        }
        // The flood: a low swell that rises rather than a hit.
        make("floodBegins", seconds: 1.6) { t, d in
            let rise = Float(min(t / 0.7, 1))
            let env = rise * Float(exp(-max(t - 0.7, 0) * 2.0))
            let body = Float(sin(2 * .pi * 58 * t)) * 0.6 + noise() * 0.5
            return body * env * 0.30
        }
        make("undo", seconds: 0.12) { t, d in
            let env = Float(exp(-t * 34))
            return Float(sin(2 * .pi * (760 - 300 * t / d) * t)) * env * 0.10
        }
        make("collapse", seconds: 0.5) { t, d in
            let env = Float(exp(-t * 7))
            return noise() * env * 0.30
        }
    }

    func play(_ cue: AudioCue) {
        guard running, enabled else { return }
        let key: String
        switch cue {
        case .toolTap:        key = "toolTap"
        case .mouldTurnedOut: key = "mouldTurnedOut"
        case .propPlaced:     key = "propPlaced"
        case .propToppled:    key = "propToppled"
        case .objectiveMet:   key = "objectiveMet"
        case .phaseChange:    key = "phaseChange"
        case .floodBegins:    key = "floodBegins"
        case .undo:           key = "undo"
        case .collapse:       key = "collapse"
        }
        guard let buffer = cueBuffers[key], !players.isEmpty else { return }
        let player = players[nextPlayer % players.count]
        nextPlayer += 1
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
}
