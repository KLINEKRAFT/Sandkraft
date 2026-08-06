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
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct RootView: View {
    @State private var engine = AppEngine()
    @State private var showingTitle = true
    @State private var startedSession = false

    var body: some View {
        ZStack {
            switch engine.state {
            case .loading:
                LoadingView()
                    .task { engine.boot() }

            case .failed(let message):
                FailureView(message: message)

            case .ready(let coordinator):
                PlayView(model: engine.model, coordinator: coordinator)
                    .opacity(showingTitle ? 0.55 : 1)
                    .blur(radius: showingTitle ? 14 : 0)
                    .allowsHitTesting(!showingTitle)

                if showingTitle {
                    // Resume appears only once there is something to resume. The
                    // beach is still there, untouched, behind the blur — the
                    // title is an overlay, not a teardown.
                    TitleView(model: engine.model,
                              onResume: startedSession
                                  ? { withAnimation(.skSlow) { showingTitle = false } }
                                  : nil) { mode, tide in
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
