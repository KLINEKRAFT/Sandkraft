//
//  PlayView.swift
//  Sandkraft
//
//  The playing screen. A full-bleed 3D scene with exactly four things floating
//  over it:
//
//    · the status strip     — what the sand is like, what you are carrying
//    · the tool rail        — what you can do about it
//    · the quick controls   — undo, look, pause
//    · the objectives       — only during a tide, and only three lines of it
//
//  Everything else is a sheet, and every sheet is dismissible with one gesture.
//  The most common failure of a game interface is that it is all present at
//  once; the fix is not smaller controls, it is fewer of them on screen.
//

import SwiftUI

struct PlayView: View {
    @Bindable var model: GameModel
    let coordinator: SceneCoordinator

    #if os(iOS)
    // horizontalSizeClass simply does not exist in EnvironmentValues on macOS,
    // so it has to be conditional rather than merely unused there.
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sheet: PlaySheet?
    @State private var showObjectives = true
    @State private var hint: String?
    @State private var hintTask: Task<Void, Never>?

    private var isCompact: Bool {
        #if os(macOS)
        return false
        #else
        return sizeClass == .compact
        #endif
    }

    var body: some View {
        ZStack {
            MetalSceneView(coordinator: coordinator)
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel("The beach")
                .accessibilityHint("Drag with one finger to use the selected tool. Drag with two to move the camera.")

            if isCompact {
                compactLayout
            } else {
                regularLayout
            }

            if model.phase == .briefing {
                TideBriefView(tide: model.tide) { model.beginTide() }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }

            if model.phase == .reckoning, let grade = model.grade {
                ResultsView(model: model, grade: grade)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .zIndex(10)
            }
        }
        .animation(.skSlow, value: model.phase)
        .sheet(item: $sheet) { which in
            // The sheet supplies its own platform chrome; see `skSheetChrome`.
            PlaySheetContent(which: which, model: model)
        }
        .skCommandRouting(model: model, coordinator: coordinator, sheet: $sheet)
        .onChange(of: model.selectedToolID) { _, newValue in
            showHint(Tool.tool(newValue).summary)
        }
        .onAppear {
            model.reducedMotion = reduceMotion
            coordinator.haptics.enabled = model.hapticsEnabled
        }
        .onChange(of: reduceMotion) { _, newValue in model.reducedMotion = newValue }
        .onChange(of: model.hapticsEnabled) { _, newValue in coordinator.haptics.enabled = newValue }
        .onChange(of: model.soundEnabled) { _, newValue in coordinator.audio.enabled = newValue }
    }

    // MARK: - Layouts

    private var compactLayout: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model, compact: true)
                .padding(.horizontal, Metric.l)
                .padding(.top, Metric.s)

            HStack(alignment: .top) {
                if model.phase.isTimed && showObjectives {
                    ObjectiveStack(model: model, compact: true)
                        .frame(maxWidth: 220, alignment: .leading)
                        .padding(.leading, Metric.l)
                        .padding(.top, Metric.m)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                QuickControls(model: model, coordinator: coordinator, sheet: $sheet, vertical: true)
                    .padding(.trailing, Metric.l)
                    .padding(.top, Metric.m)
            }

            Spacer(minLength: 0)

            if let hint {
                HintBubble(text: hint)
                    .padding(.bottom, Metric.s)
            }

            ToolRail(model: model, sheet: $sheet, axis: .horizontal)
                .padding(.horizontal, Metric.m)
                .padding(.bottom, Metric.s)
        }
        .animation(.skSnap, value: hint)
        .animation(.skSnap, value: showObjectives)
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            ToolRail(model: model, sheet: $sheet, axis: .vertical)
                .padding(.leading, Metric.l)
                .padding(.vertical, Metric.l)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: Metric.m) {
                    StatusStrip(model: model, compact: false)
                    Spacer(minLength: Metric.l)
                    QuickControls(model: model, coordinator: coordinator, sheet: $sheet, vertical: false)
                }
                .padding(.horizontal, Metric.l)
                .padding(.top, Metric.l)

                Spacer(minLength: 0)

                if let hint {
                    HintBubble(text: hint).padding(.bottom, Metric.l)
                }
            }

            if model.phase.isTimed {
                ObjectiveStack(model: model, compact: false)
                    .frame(width: Metric.inspectorWidth)
                    .padding(.trailing, Metric.l)
                    .padding(.vertical, Metric.l)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.skSnap, value: hint)
    }

    private func showHint(_ text: String) {
        hintTask?.cancel()
        hint = text
        hintTask = Task {
            // Long enough to read a short sentence, short enough that it is never
            // in the way of the thing it is describing.
            try? await Task.sleep(for: .seconds(2.6))
            if !Task.isCancelled { hint = nil }
        }
    }
}

// MARK: - Status

struct StatusStrip: View {
    @Bindable var model: GameModel
    var compact: Bool

    private var clockProgress: Double {
        guard let remaining = model.secondsRemaining else { return 0 }
        let total = model.phase == .building ? model.tide.buildSeconds : model.tide.floodSeconds
        return 1 - remaining / max(total, 1)
    }

    var body: some View {
        HStack(spacing: compact ? Metric.m : Metric.xl) {
            MoistureReadout(moisture: model.hoverMoisture,
                            packing: model.hoverPacking,
                            valid: model.hoverValid)

            if !compact {
                Divider().frame(height: 28)
            }

            PailMeter(fraction: model.pailFraction,
                      moisture: model.pailMoisture,
                      isEmpty: model.pailIsEmpty && model.mode != .shore)

            Spacer(minLength: Metric.s)

            if model.phase.isTimed {
                TideClock(progress: clockProgress,
                          phaseName: model.phase == .building ? "Building" : "Flood",
                          detail: model.phase == .building
                              ? "\(Int(model.secondsRemaining ?? 0))s to the turn"
                              : "the water is coming",
                          urgent: model.phase == .flooding || (model.secondsRemaining ?? 99) < 25)
            } else {
                DayReadout(model: model)
            }
        }
        .padding(.horizontal, Metric.l)
        .padding(.vertical, Metric.m)
        .skPanel(radius: Metric.radiusLarge, material: .thinMaterial)
    }
}

struct DayReadout: View {
    @Bindable var model: GameModel

    var body: some View {
        HStack(spacing: Metric.s) {
            GlyphView(glyph: model.atmosphere.night > 0.5 ? .cloud : .sun, size: 17, weight: 1.6)
                .foregroundStyle(model.atmosphere.night > 0.5 ? Palette.tide : Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(SunPath.clockText(dayFraction: model.dayFraction))
                    .font(.skNumeric(13, weight: .semibold))
                Text(SunPath.phaseName(dayFraction: model.dayFraction))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time of day")
        .accessibilityValue("\(SunPath.clockText(dayFraction: model.dayFraction)), \(SunPath.phaseName(dayFraction: model.dayFraction))")
    }
}

// MARK: - Objectives

struct ObjectiveStack: View {
    @Bindable var model: GameModel
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Metric.s : Metric.m) {
            PanelHeading(title: "Tide \(model.tideNumber) · \(model.tide.name)")
            ForEach(Array(model.tide.objectives.enumerated()), id: \.offset) { index, objective in
                ObjectiveRow(text: compact ? objective.shortText : objective.text,
                             progress: objective.progress(model.result),
                             met: index < model.objectivesMet.count && model.objectivesMet[index],
                             compact: compact)
            }
            if !compact {
                Divider().padding(.vertical, Metric.xs)
                HStack {
                    Text("Standing")
                        .font(.skLabel)
                        .foregroundStyle(Palette.secondaryText)
                    Spacer()
                    Text("\(Int(model.result.standing))")
                        .font(.skNumeric(20, weight: .semibold))
                        .contentTransition(.numericText())
                }
                Text(model.tide.epigraph)
                    .font(.skSerif(13))
                    .italic()
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? Metric.m : Metric.l)
        .skPanel(radius: Metric.radiusLarge, material: .thinMaterial)
        .animation(.skSnap, value: model.objectivesMet)
    }
}

// MARK: - Quick controls

struct QuickControls: View {
    @Bindable var model: GameModel
    let coordinator: SceneCoordinator
    @Binding var sheet: PlaySheet?
    var vertical: Bool

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: Metric.s))
            : AnyLayout(HStackLayout(spacing: Metric.s))

        layout {
            IconButton(glyph: .undo, label: "Undo", enabled: model.canUndo) {
                coordinator.undo()
            }
            IconButton(glyph: .redo, label: "Redo", enabled: model.canRedo) {
                coordinator.redo()
            }
            IconButton(glyph: .layers, label: "Look") { sheet = .look }
            IconButton(glyph: model.isPaused ? .play : .pause,
                       label: model.isPaused ? "Resume" : "Pause") {
                model.isPaused.toggle()
            }
            IconButton(glyph: .settings, label: "Settings") { sheet = .settings }
        }
    }
}

// MARK: - Tool rail

struct ToolRail: View {
    @Bindable var model: GameModel
    @Binding var sheet: PlaySheet?
    var axis: Axis

    @State private var family: ToolFamily = .material

    private var tools: [Tool] {
        model.availableTools.filter { $0.family == family }
    }

    var body: some View {
        Group {
            if axis == .horizontal {
                VStack(spacing: Metric.s) {
                    familyPicker
                    toolStrip
                    contextRow
                }
                .padding(Metric.m)
                .skPanel()
            } else {
                VStack(spacing: Metric.m) {
                    ForEach(ToolFamily.allCases) { f in
                        VStack(spacing: Metric.xs) {
                            Text(f.title.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.secondaryText)
                            ForEach(model.availableTools.filter { $0.family == f }) { tool in
                                ToolChip(tool: tool,
                                         selected: model.selectedToolID == tool.id,
                                         showsShortcut: true) {
                                    model.selectedToolID = tool.id
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    contextRow
                }
                .padding(Metric.m)
                .frame(width: Metric.sidebarWidth + 12)
                .skPanel()
            }
        }
        .animation(.skSnap, value: family)
        .onChange(of: model.selectedToolID) { _, newValue in
            // Keep the segment in step when a tool is chosen from the keyboard or
            // the menu bar rather than from the rail.
            family = Tool.tool(newValue).family
        }
    }

    private var familyPicker: some View {
        HStack(spacing: 2) {
            ForEach(ToolFamily.allCases) { f in
                Button {
                    family = f
                } label: {
                    Text(f.title)
                        .font(.system(size: 12, weight: family == f ? .semibold : .regular))
                        .foregroundStyle(family == f ? Palette.primaryText : Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metric.xs + 2)
                        .background {
                            if family == f {
                                RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                                    .fill(Palette.primaryText.opacity(0.10))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(family == f ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: Metric.radiusSmall + 2, style: .continuous)
                .fill(Palette.primaryText.opacity(0.05))
        }
    }

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metric.xs) {
                ForEach(tools) { tool in
                    ToolChip(tool: tool, selected: model.selectedToolID == tool.id) {
                        model.selectedToolID = tool.id
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 60)
    }

    /// What the current tool needs beyond itself: a mould, an adornment, or a
    /// size. Only ever one row, and it is empty for the tools that need nothing.
    @ViewBuilder
    private var contextRow: some View {
        switch model.selectedToolID {
        case .mould:
            Button { sheet = .mould } label: {
                HStack(spacing: Metric.s) {
                    GlyphView(glyph: model.mould.glyph, size: 20, weight: 1.6)
                    Text(model.mould.name).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("Change").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, Metric.m)
                .padding(.vertical, Metric.s)
                .background {
                    RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                        .fill(Palette.primaryText.opacity(0.06))
                }
            }
            .buttonStyle(.plain)
        case .place:
            Button { sheet = .adornment } label: {
                HStack(spacing: Metric.s) {
                    GlyphView(glyph: model.adornment.glyph, size: 20, weight: 1.6)
                    Text(model.adornment.name).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("Change").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, Metric.m)
                .padding(.vertical, Metric.s)
                .background {
                    RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                        .fill(Palette.primaryText.opacity(0.06))
                }
            }
            .buttonStyle(.plain)
        default:
            HStack(spacing: Metric.s) {
                Text("Size").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                Slider(value: $model.brushScale, in: 0.45...2.0)
                    .controlSize(.small)
                    .tint(Palette.accent)
                Text(String(format: "%.1f×", model.brushScale))
                    .font(.skNumeric(11))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 34, alignment: .trailing)
            }
            .accessibilityElement(children: .contain)
        }
    }
}
