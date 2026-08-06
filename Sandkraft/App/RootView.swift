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
            let tier = context.recommendedTier
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
                    TitleView(model: engine.model) { mode, tide in
                        engine.model.start(mode: mode, tide: tide)
                        coordinator.resetBeach()
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
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #endif
    }
}

// MARK: - Launch states

struct LoadingView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(spacing: Metric.l) {
            // A tide line, drawn once and animated. No spinner: a spinner says
            // "something is happening"; this says "the sea is happening".
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    var path = Path()
                    let steps = 60
                    for i in 0...steps {
                        let x = size.width * CGFloat(i) / CGFloat(steps)
                        let y = size.height / 2
                            + sin(CGFloat(i) / CGFloat(steps) * 6 + t * 1.4) * 6
                            + sin(CGFloat(i) / CGFloat(steps) * 11 - t * 0.9) * 3
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(Palette.accent.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            .frame(width: 180, height: 40)

            Text("SANDKRAFT")
                .font(.system(size: 18, weight: .light, design: .serif))
                .tracking(8)
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
                .font(.skSerif(24, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("""
                 The whole of this game runs on the GPU — the sand, the water and \
                 the light. There is no version of it that runs without one.
                 """)
                .font(.skSerif(13))
                .italic()
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
