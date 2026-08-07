//
//  RootView.swift
//  Sandkraft
//
//  Owns the one thing in the app that can fail at launch — building a Metal
//  device, a shader library and a simulation — and routes between the title and
//  the beach.
//
//  If Metal is unavailable the app says so in a sentence and stops. It does not
//  fall back to a software renderer, because there is no version of this game
//  without a GPU: the sand *is* the GPU.
//

import SwiftUI
import Metal

@MainActor
@Observable
final class AppEngine {
    enum State {
        case loading
        case ready(SceneCoordinator)
        case failed(String)
    }

    private(set) var state: State = .loading
    let model = GameModel()

    /// The autosaved beach, if there is one and it fits this session's
    /// simulation resolution. Read once at boot: the file does not change while
    /// we are the ones writing it, and the title screen asking the disk a
    /// question on every body evaluation would be a strange way to find out.
    private(set) var restorableBeach: BeachHeader?

    func boot() {
        guard case .loading = state else { return }
        do {
            let context = try MetalContext()

            // A tier the player chose outranks the one we would guess. That
            // ordering is the entire point: guessing is what handed this machine
            // Maximum in the first place, and having to correct the guess on
            // every single launch is worse than the guess was.
            let stored = Preferences.load()
            model.apply(stored)

            let tier = stored.qualityTier ?? context.recommendedTier
            model.qualityTier = tier
            let renderer = try Renderer(context: context, tier: tier)
            let coordinator = SceneCoordinator(renderer: renderer, model: model)

            // Offered, never imposed. Continuing puts back a beach the player
            // may well have finished with, and there is no way to tell from here
            // which it was — so the title screen asks.
            if let header = BeachStore.storedHeader(),
               header.simResolution == renderer.simulation.resolution {
                restorableBeach = header
            }

            state = .ready(coordinator)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Rebuild the simulation at a new quality tier. The beach is laid down
    /// fresh, which is why the settings screen says so out loud rather than
    /// silently throwing away the player's castle.
    func applyQuality(_ tier: QualityTier) {
        guard case .ready(let coordinator) = state else { return }
        do {
            try coordinator.renderer.apply(tier: tier)
            coordinator.resetBeach()
            // The stored beach was written at the old resolution, so it can no
            // longer be loaded into this session. Dropping the offer here is
            // what stops Continue from being a button that reports an error.
            restorableBeach = nil
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Continuing consumes the offer. It is a door back into one session, not a
    /// checkpoint to keep returning to — the beach it restores is live from the
    /// moment it lands, and Resume is what comes back to it after that.
    func consumeRestorableBeach() {
        restorableBeach = nil
    }
}

struct RootView: View {
    @State private var engine = AppEngine()
    @State private var showingTitle = true
    @State private var startedSession = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch engine.state {
            case .loading:
                LoadingView()
                    .task { engine.boot() }

            case .failed(let message):
                FailureView(message: message)

            case .ready(let coordinator):
                // Barely touched while the title is up. The old settings — 55%
                // opacity under a fourteen-point blur — turned the beach into a
                // smear behind a sheet of glass, which is exactly the look the
                // title screen was rewritten to get away from. The scrim in
                // TitleView does the legibility work now, and it only does it
                // where the words are.
                PlayView(model: engine.model, coordinator: coordinator)
                    .opacity(showingTitle ? 0.85 : 1)
                    .blur(radius: showingTitle ? 4 : 0)
                    .allowsHitTesting(!showingTitle)

                if showingTitle {
                    // Resume appears only once there is something to resume. The
                    // beach is still there, untouched, behind the scrim — the
                    // title is an overlay, not a teardown.
                    //
                    // Continue is the other half of that, across launches rather
                    // than within one: it appears only before the first session,
                    // because after that Resume is the same door and the better
                    // word for it.
                    TitleView(model: engine.model,
                              storedBeach: startedSession ? nil : engine.restorableBeach,
                              onResume: startedSession
                                  ? { withAnimation(.skSlow) { showingTitle = false } }
                                  : nil,
                              onContinue: {
                                  guard coordinator.restoreAutosavedBeach() else {
                                      engine.consumeRestorableBeach()
                                      return
                                  }
                                  engine.consumeRestorableBeach()
                                  startedSession = true
                                  withAnimation(.skSlow) { showingTitle = false }
                              }) { mode, tide in
                        engine.model.start(mode: mode, tide: tide)
                        coordinator.resetBeach()
                        startedSession = true
                        withAnimation(.skSlow) { showingTitle = false }
                    }
                    .transition(.opacity)
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .environment(\.skReturnToTitle, { withAnimation(.skSlow) { showingTitle = true } })
        .onChange(of: engine.model.qualityTier) { _, newValue in
            engine.applyQuality(newValue)
        }
        // The one save site. Reading `preferences` here observes every property
        // it gathers, so any of them changing lands the whole set in
        // UserDefaults — which coalesces its own writes, so a slider being
        // dragged does not mean a slider being written sixty times a second.
        .onChange(of: engine.model.preferences) { _, latest in
            Preferences.save(latest)
        }
        // Leaving the app is the one moment the thirty-second autosave timer
        // cannot help with, so ask for one on the way out. It may not land —
        // see `requestAutosave` — which is exactly why it is not the mechanism.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, case .ready(let coordinator) = engine.state else { return }
            coordinator.requestAutosave()
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #endif
    }
}

// MARK: - Launch states

struct LoadingView: View {

    /// Two sine terms over a normalised span. Every value is explicitly CGFloat.
    ///
    /// Written out longhand on purpose: the obvious one-expression version mixes
    /// CGFloat from the canvas size with the TimeInterval from the timeline, and
    /// the type-checker gives up trying to reconcile the literals. This is not a
    /// style preference — it is the difference between compiling and not.
    private func tideLine(in size: CGSize, phase: CGFloat) -> Path {
        var path = Path()
        let steps = 60
        let midY: CGFloat = size.height / 2
        for i in 0...steps {
            let u = CGFloat(i) / CGFloat(steps)
            let x: CGFloat = size.width * u
            let swell: CGFloat = sin(u * 6 + phase * 1.4) * 6
            let chop: CGFloat = sin(u * 11 - phase * 0.9) * 3
            let y: CGFloat = midY + swell + chop
            let point = CGPoint(x: x, y: y)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    var body: some View {
        VStack(spacing: Metric.l) {
            // A tide line, drawn once and animated. No spinner: a spinner says
            // "something is happening"; this says "the sea is happening".
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
                    context.stroke(tideLine(in: size, phase: phase),
                                   with: .color(Palette.accent.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .frame(width: 180, height: 40)

            Text("SANDKRAFT")
                .font(.skDisplay(15, weight: .light))
                .tracking(9)
                .foregroundStyle(Palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityLabel("Loading")
    }
}

struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: Metric.l) {
            Text("Sandkraft cannot start")
                .font(.skDisplay(22, weight: .regular))
            Text(message)
                .font(.skProse(13))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("""
                 The whole of this game runs on the GPU — the sand, the water and \
                 the light. There is no version of it that runs without one.
                 """)
                .font(.skProse(12))
                .lineSpacing(skProseSpacing)
                .foregroundStyle(Palette.secondaryText.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(Metric.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Environment

private struct ReturnToTitleKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var skReturnToTitle: () -> Void {
        get { self[ReturnToTitleKey.self] }
        set { self[ReturnToTitleKey.self] = newValue }
    }
}
