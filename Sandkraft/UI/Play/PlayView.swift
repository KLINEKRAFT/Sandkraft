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
import UniformTypeIdentifiers

/// A PNG on its way to wherever the player wants to put it.
///
/// `fileExporter` wants a `FileDocument`, and the bytes already exist, so this
/// is the thinnest possible wrapper around them. Reading is implemented only
/// because the protocol insists — nothing in this app opens a photograph.
struct PhotoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// Built from the extension rather than declared with `exportedAs`, which
    /// requires a matching `UTExportedTypeDeclarations` entry in Info.plist and
    /// traps at runtime without one. A dynamic type filters the open panel by
    /// extension, which is the whole of what is needed here.
    static var sandkraftBeach: UTType {
        UTType(filenameExtension: "sandkraft", conformingTo: .data) ?? .data
    }
}

/// A saved beach on its way to or from disk.
struct BeachFile: FileDocument {
    static var readableContentTypes: [UTType] { [.sandkraftBeach] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

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
    /// Everything off but the sand. The beach has always been full-bleed behind
    /// the panels; this is the difference between a beach you can see all of and
    /// one with four hundred points of glass parked on top of it.
    @State private var chromeHidden = false
    @State private var hint: String?
    @State private var hintTask: Task<Void, Never>?
    @State private var photo: PhotoDocument?
    @State private var exportingPhoto = false
    @State private var beach: BeachFile?
    @State private var exportingBeach = false
    @State private var importingBeach = false

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

            if chromeHidden {
                revealControl
            } else if isCompact {
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
        .animation(.skSnap, value: chromeHidden)
        .sheet(item: $sheet) { which in
            // The sheet supplies its own platform chrome; see `skSheetChrome`.
            PlaySheetContent(which: which, model: model)
        }
        .skCommandRouting(model: model, coordinator: coordinator,
                          sheet: $sheet, chromeHidden: $chromeHidden)
        .onChange(of: model.selectedToolID) { _, newValue in
            showHint(Tool.tool(newValue).summary)
        }
        // Nothing on screen said which of the nine looks you were in, which
        // matters most for the one way of changing it that shows no interface at
        // all — ⌘L. Reusing the hint that already exists for tools costs three
        // lines and no pixels when it is not being changed.
        .onChange(of: model.lookID) { _, newValue in
            let look = Look.look(newValue)
            showHint("\(look.name) — \(look.note)")
        }
        .onAppear {
            model.reducedMotion = reduceMotion
            coordinator.haptics.enabled = model.hapticsEnabled
        }
        // Watched as a Bool rather than as the `Data` itself: `onChange` compares
        // old against new on every body evaluation, and that would mean an
        // equality check over several megabytes of PNG for every frame the
        // interface happens to update on.
        .onChange(of: model.pendingPhoto != nil) { _, arrived in
            guard arrived, let data = model.pendingPhoto else { return }
            photo = PhotoDocument(data: data)
            exportingPhoto = true
            model.pendingPhoto = nil
        }
        .fileExporter(isPresented: $exportingPhoto,
                      document: photo,
                      contentType: .png,
                      defaultFilename: FrameCapture.suggestedFilename()) { result in
            photo = nil
            switch result {
            case .success: showHint("Photograph saved.")
            case .failure: showHint("The photograph could not be saved.")
            }
        }
        .onChange(of: model.openBeachWanted) { _, wants in
            guard wants else { return }
            model.openBeachWanted = false
            importingBeach = true
        }
        .onChange(of: model.pendingBeach != nil) { _, ready in
            guard ready, let data = model.pendingBeach else { return }
            beach = BeachFile(data: data)
            exportingBeach = true
            model.pendingBeach = nil
        }
        .fileExporter(isPresented: $exportingBeach,
                      document: beach,
                      contentType: .sandkraftBeach,
                      defaultFilename: BeachDocumentFormat.suggestedFilename()) { result in
            beach = nil
            switch result {
            case .success: showHint("Beach saved.")
            case .failure: showHint("The beach could not be saved.")
            }
        }
        .fileImporter(isPresented: $importingBeach,
                      allowedContentTypes: [.sandkraftBeach]) { result in
            switch result {
            case .success(let url):
                // Sandboxed, so the panel's grant has to be opened explicitly
                // and closed again — without this the read fails with a
                // permission error on a file the player just chose by hand.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    model.pendingBeachLoad = data
                } else {
                    showHint("That beach could not be read.")
                }
            case .failure:
                showHint("That beach could not be opened.")
            }
        }
        .onChange(of: model.beachMessage != nil) { _, hasMessage in
            guard hasMessage, let message = model.beachMessage else { return }
            showHint(message)
            model.beachMessage = nil
        }
        .onChange(of: reduceMotion) { _, newValue in model.reducedMotion = newValue }
        .onChange(of: model.hapticsEnabled) { _, newValue in coordinator.haptics.enabled = newValue }
        .onChange(of: model.soundEnabled) { _, newValue in coordinator.audio.enabled = newValue }
    }

    // MARK: - Layouts

    /// What is left when everything is hidden: one button, in the corner the
    /// tool rail is not in. Deliberately not *nothing* — a mode with no way out
    /// of it that is not a keyboard shortcut is a trap on a phone.
    private var revealControl: some View {
        VStack {
            HStack {
                Spacer(minLength: 0)
                IconButton(glyph: .collapse, label: "Show the controls", size: 38, glyphSize: 17) {
                    chromeHidden = false
                }
                .opacity(0.55)
            }
            Spacer(minLength: 0)
        }
        .padding(Metric.l)
        .transition(.opacity)
    }

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
                QuickControls(model: model, coordinator: coordinator, sheet: $sheet,
                              chromeHidden: $chromeHidden, showObjectives: $showObjectives,
                              vertical: true)
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

    /// The rail and the inspector are laid out beside the middle column rather
    /// than over it, which is what keeps the status strip and the hint from
    /// sliding underneath them. The scene itself is behind all three and always
    /// was: it is the ZStack's first layer, full-bleed, and none of this crops
    /// it. What the panels cost is *sight of* the beach, which is why both ends
    /// of this row can now be put away — the objectives with their own button,
    /// everything at once with `chromeHidden`.
    private var regularLayout: some View {
        HStack(spacing: 0) {
            ToolRail(model: model, sheet: $sheet, axis: .vertical)
                .padding(.leading, Metric.l)
                .padding(.vertical, Metric.l)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: Metric.m) {
                    StatusStrip(model: model, compact: false)
                    Spacer(minLength: Metric.l)
                    QuickControls(model: model, coordinator: coordinator, sheet: $sheet,
                                  chromeHidden: $chromeHidden, showObjectives: $showObjectives,
                                  vertical: false)
                }
                .padding(.horizontal, Metric.l)
                .padding(.top, Metric.l)

                Spacer(minLength: 0)

                if let hint {
                    HintBubble(text: hint).padding(.bottom, Metric.l)
                }
            }

            if model.phase.isTimed && showObjectives {
                ObjectiveStack(model: model, compact: false)
                    .frame(width: Metric.inspectorWidth)
                    .padding(.trailing, Metric.l)
                    .padding(.vertical, Metric.l)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.skSnap, value: hint)
        .animation(.skSnap, value: showObjectives)
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
                    .font(Typeface.font(10, .regular))
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
                    .font(.skProse(12))
                    .lineSpacing(skProseSpacing - 2)
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
    @Binding var chromeHidden: Bool
    @Binding var showObjectives: Bool
    var vertical: Bool

    @Environment(\.skReturnToTitle) private var returnToTitle

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
            IconButton(glyph: .camera, label: "Photograph") { model.takePhoto() }
            IconButton(glyph: .layers, label: "Look") { sheet = .look }

            // Only during a tide, because outside one there is nothing in the
            // panel to hide.
            if model.phase.isTimed {
                IconButton(glyph: .tide,
                           label: showObjectives ? "Hide the objectives" : "Show the objectives") {
                    showObjectives.toggle()
                }
                .opacity(showObjectives ? 1 : 0.55)
            }

            IconButton(glyph: model.isPaused ? .play : .pause,
                       label: model.isPaused ? "Resume" : "Pause") {
                model.isPaused.toggle()
            }
            IconButton(glyph: .expand, label: "Hide the controls") { chromeHidden = true }
            IconButton(glyph: .settings, label: "Settings") { sheet = .settings }
            // `skReturnToTitle` has been in the environment since the first
            // build and nothing ever read it, so there was no way back to the
            // title at all. Leaving is non-destructive — the beach stays exactly
            // as it is behind the title, and Resume comes back to it.
            IconButton(glyph: .close, label: "Title screen") { returnToTitle() }
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
                                .font(Typeface.font(9, .semibold))
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
                        .font(Typeface.font(12, family == f ? .semibold : .regular))
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
        // Six points off the tool strip is six points of beach back on a phone,
        // where the rail is the single largest thing between the player and the
        // sand. The chips were never sixty points tall; the frame was.
        .frame(height: 54)
    }

    /// What the current tool needs beyond itself: a mould, an adornment, or a
    /// size. Adornments are the only thing that does not take a size — a mould
    /// scales off the very same multiplier the brushes do, so hiding the size
    /// control while one was selected meant switching tool, resizing, and
    /// switching back to change how big a turret you were about to turn out.
    @ViewBuilder
    private var contextRow: some View {
        switch model.selectedToolID {
        case .mould:
            VStack(spacing: Metric.s) {
                Button { sheet = .mould } label: {
                    HStack(spacing: Metric.s) {
                        GlyphView(glyph: model.mould.glyph, size: 20, weight: 1.6)
                        Text(model.mould.name).font(Typeface.font(12, .medium))
                        Spacer(minLength: 0)
                        Text("Change").font(Typeface.font(11, .regular)).foregroundStyle(Palette.secondaryText)
                    }
                    .padding(.horizontal, Metric.m)
                    .padding(.vertical, Metric.s)
                    .background {
                        RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                            .fill(Palette.primaryText.opacity(0.06))
                    }
                }
                .buttonStyle(.plain)

                BrushSizeChip(model: model, axis: axis)
            }
        case .place:
            Button { sheet = .adornment } label: {
                HStack(spacing: Metric.s) {
                    GlyphView(glyph: model.adornment.glyph, size: 20, weight: 1.6)
                    Text(model.adornment.name).font(Typeface.font(12, .medium))
                    Spacer(minLength: 0)
                    Text("Change").font(Typeface.font(11, .regular)).foregroundStyle(Palette.secondaryText)
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
            BrushSizeChip(model: model, axis: axis)
        }
    }
}

// MARK: - Brush size and shape

/// The footprint, drawn. Shared by the chip and the editor so the little mark in
/// the rail is literally the same shape as the option you picked.
struct BrushShapeGlyph: View {
    let shape: BrushShape

    var body: some View {
        switch shape {
        case .round:
            Circle().strokeBorder(lineWidth: 1.5)
        case .square:
            RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(lineWidth: 1.5)
        }
    }
}

/// What sits in the rail: the current footprint and the current size, and a way
/// in to change them.
///
/// The first attempt put the whole control — two steppers, a slider, a readout
/// and a shape toggle — inline. In the horizontal rail that is merely tight; in
/// the vertical one it is impossible. That rail is `Metric.sidebarWidth + 12`
/// wide, so after padding there are about eighty points to play with, and a
/// slider sharing eighty points with four other controls is a slider with no
/// width at all. Which is exactly how it shipped, and exactly how it looked.
///
/// So the rail carries the *reading* — always visible, no interaction needed —
/// and the adjusting happens in a popover with room to do it in.
struct BrushSizeChip: View {
    @Bindable var model: GameModel
    var axis: Axis

    @State private var editing = false

    var body: some View {
        Button {
            editing = true
        } label: {
            label
                .padding(.horizontal, Metric.s)
                .padding(.vertical, Metric.s)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                        .fill(Palette.primaryText.opacity(0.06))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Brush size and shape")
        .accessibilityValue(model.brushSizeDescription)
        .popover(isPresented: $editing) {
            BrushSizeEditor(model: model)
                // Without this an iPhone turns a popover into a sheet, and a
                // sheet for one slider is a sledgehammer.
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var label: some View {
        if axis == .vertical {
            VStack(spacing: 3) {
                BrushShapeGlyph(shape: model.brushShape)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Palette.accent)
                Text(model.brushSizeDescription)
                    .font(.skNumeric(11))
                    .foregroundStyle(Palette.primaryText)
            }
        } else {
            HStack(spacing: Metric.s) {
                BrushShapeGlyph(shape: model.brushShape)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(Palette.accent)
                Text("Size")
                    .font(Typeface.font(11, .regular))
                    .foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 0)
                Text(model.brushSizeDescription)
                    .font(.skNumeric(11))
                    .foregroundStyle(Palette.primaryText)
            }
        }
    }
}

/// The popover. Fixed 280 points wide, which leaves the slider about 180 — the
/// difference between a control you can place and one you can only nudge.
struct BrushSizeEditor: View {
    @Bindable var model: GameModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.l) {
            VStack(alignment: .leading, spacing: Metric.s) {
                HStack {
                    Text("Size").skLabelStyle()
                    Spacer(minLength: 0)
                    Text(model.brushSizeDescription)
                        .font(.skNumeric(13, weight: .medium))
                        .foregroundStyle(Palette.primaryText)
                }

                HStack(spacing: Metric.m) {
                    stepButton("−", steps: -1)
                    Slider(value: $model.brushScaleExponent,
                           in: GameModel.brushExponentRange)
                        .tint(Palette.accent)
                        .accessibilityLabel("Brush size")
                        .accessibilityValue(model.brushSizeDescription)
                    stepButton("+", steps: 1)
                }

                Text("Across, for the tool in hand. The keys [ and ] step by the same amount.")
                    .font(.skCaption)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Metric.s) {
                Text("Shape").skLabelStyle()

                HStack(spacing: Metric.s) {
                    ForEach(BrushShape.allCases) { option in
                        Button {
                            model.brushShape = option
                        } label: {
                            HStack(spacing: Metric.s) {
                                BrushShapeGlyph(shape: option)
                                    .frame(width: 13, height: 13)
                                Text(option.title)
                                    .font(Typeface.font(12, .regular))
                            }
                            .foregroundStyle(option == model.brushShape
                                             ? Palette.accent : Palette.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Metric.s)
                            .background {
                                RoundedRectangle(cornerRadius: Metric.radiusSmall, style: .continuous)
                                    .fill(Palette.primaryText
                                        .opacity(option == model.brushShape ? 0.12 : 0.05))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == model.brushShape
                                                ? [.isSelected, .isButton] : .isButton)
                    }
                }

                Text("Applies to every tool at once.")
                    .font(.skCaption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(Metric.l)
        .frame(width: 280)
    }

    private func stepButton(_ label: String, steps: Double) -> some View {
        // Bound to a `String` before it reaches the modifier. A ternary of two
        // string *literals* has to be disambiguated against the LocalizedStringKey
        // overload, and that is a needless bet to hand the type-checker.
        let spoken: String = steps > 0 ? "Larger brush" : "Smaller brush"

        return Button {
            model.nudgeBrushSize(by: steps)
        } label: {
            Text(label)
                .font(.skNumeric(15, weight: .medium))
                .foregroundStyle(Palette.primaryText)
                .frame(width: 32, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: Metric.radiusSmall - 2, style: .continuous)
                        .fill(Palette.primaryText.opacity(0.08))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.soft)
        .accessibilityLabel(spoken)
    }
}
