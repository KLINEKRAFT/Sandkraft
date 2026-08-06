//
//  Menus.swift
//  Sandkraft
//
//  The title screen, the card before a tide, and the card after one.
//
//  All three are typographic. There is no artwork behind them because there does
//  not need to be: the beach is already rendering behind the glass, at whatever
//  time of day the coming tide is set at, and a still image would be a downgrade.
//

import SwiftUI

// MARK: - Title

struct TitleView: View {
    @Bindable var model: GameModel
    var onStart: (GameMode, Int) -> Void
    @State private var selectedMode: GameMode = .shore
    @State private var showingFieldNotes = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: Metric.xxl)

                VStack(spacing: Metric.m) {
                    Text("SANDKRAFT")
                        .font(.skDisplay(38, weight: .ultraLight))
                        .tracking(16)
                        // Tracking adds space after the *last* letter too, so a
                        // centred word sits visibly left of centre. Half the
                        // tracking back on the leading edge squares it up.
                        .padding(.leading, 16)
                        .skLegible()

                    Text("A sandcastle simulator")
                        .skLabelStyle(Palette.secondaryText, tracking: 3)
                        .skLegible()
                }
                .padding(.bottom, Metric.xxxl)

                VStack(spacing: Metric.m) {
                    ForEach(GameMode.allCases) { mode in
                        ModeCard(mode: mode,
                                 selected: selectedMode == mode,
                                 progress: mode == .tides ? model.campaignProgress : nil) {
                            withAnimation(.skSnap) { selectedMode = mode }
                        }
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, Metric.l)

                if selectedMode == .tides {
                    TidePicker(model: model) { number in
                        onStart(.tides, number)
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, Metric.l)
                    .padding(.top, Metric.m)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer(minLength: Metric.l)

                BrandMark(height: 24)
                    .padding(.bottom, Metric.xl)
                    .skLegible()

                HStack(spacing: Metric.m) {
                    Button {
                        showingFieldNotes = true
                    } label: {
                        Text("Field Notes")
                            .font(.skDisplay(12, weight: .medium))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .padding(.horizontal, Metric.l)
                            .padding(.vertical, Metric.m)
                            .skPanel(radius: Metric.radiusLarge, material: .thinMaterial)
                    }
                    .buttonStyle(.soft)

                    if selectedMode != .tides {
                        Button {
                            onStart(selectedMode, 1)
                        } label: {
                            Text("Begin")
                                .font(.skDisplay(14, weight: .medium))
                                .tracking(1.5)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.black.opacity(0.85))
                                .padding(.horizontal, Metric.xxl)
                                .padding(.vertical, Metric.m)
                                .background {
                                    Capsule().fill(Palette.accent)
                                }
                        }
                        .buttonStyle(.soft)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.bottom, Metric.xxl)
            }
            .animation(.skSnap, value: selectedMode)
        }
        .sheet(isPresented: $showingFieldNotes) {
            NavigationStack {
                FieldNotesView()
                    .navigationTitle("Field Notes")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingFieldNotes = false }
                        }
                    }
            }
            .skSheetChrome(large: true)
        }
    }
}

struct ModeCard: View {
    let mode: GameMode
    let selected: Bool
    let progress: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metric.l) {
                VStack(alignment: .leading, spacing: Metric.xs) {
                    HStack(spacing: Metric.s) {
                        Text(mode.title)
                            .font(.skDisplay(17, weight: .regular))
                            .tracking(0.5)
                        if let progress, progress > 1 {
                            Text("tide \(min(progress, 9)) of 9")
                                .font(Typeface.font(10, .semibold))
                                .foregroundStyle(Palette.accent)
                                .padding(.horizontal, Metric.s)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(Palette.accent.opacity(0.15)) }
                        }
                    }
                    Text(selected ? mode.longDescription : mode.subtitle)
                        .font(.skProse(11))
                        .lineSpacing(skProseSpacing - 2)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Circle()
                    .strokeBorder(selected ? Palette.accent : Palette.primaryText.opacity(0.2),
                                  lineWidth: selected ? 5 : 1.5)
                    .frame(width: 18, height: 18)
                    .padding(.top, 4)
            }
            .padding(Metric.l)
            .skPanel(radius: Metric.radiusLarge,
                     material: selected ? .regularMaterial : .thinMaterial)
            .contentShape(RoundedRectangle(cornerRadius: Metric.radiusLarge, style: .continuous))
        }
        .buttonStyle(.soft)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

struct TidePicker: View {
    @Bindable var model: GameModel
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s) {
            PanelHeading(title: "Choose a tide",
                         caption: "Each one is harder, later in the day, and takes more away.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: Metric.s)], spacing: Metric.s) {
                ForEach(Tide.campaign) { tide in
                    let unlocked = tide.number <= model.campaignProgress
                    Button {
                        if unlocked { onPick(tide.number) }
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(tide.number)")
                                .font(.skNumeric(20, weight: .semibold))
                            Text(tide.name)
                                .font(Typeface.font(10, .regular))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(height: 26)
                        }
                        .foregroundStyle(unlocked ? Palette.primaryText : Palette.secondaryText.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metric.s)
                        .background {
                            RoundedRectangle(cornerRadius: Metric.radiusMedium, style: .continuous)
                                .fill(Palette.primaryText.opacity(unlocked ? 0.07 : 0.03))
                        }
                    }
                    .buttonStyle(.soft)
                    .disabled(!unlocked)
                    .accessibilityLabel("Tide \(tide.number), \(tide.name)")
                    .accessibilityHint(unlocked ? "Begin this tide" : "Locked")
                }
            }
        }
        .padding(Metric.l)
        .skPanel(radius: Metric.radiusLarge, material: .thinMaterial)
    }
}

// MARK: - Tide brief

struct TideBriefView: View {
    let tide: Tide
    var onBegin: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()

            VStack(spacing: Metric.l) {
                VStack(spacing: Metric.xs) {
                    Text("TIDE \(tide.number)")
                        .font(.skLabel)
                        .foregroundStyle(Palette.accent)
                    Text(tide.name)
                        .font(.skDisplay(26, weight: .light))
                        .tracking(2)
                        .multilineTextAlignment(.center)
                }

                Text(tide.epigraph)
                    .font(.skProse(13))
                    .lineSpacing(skProseSpacing)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metric.m)

                Divider()

                VStack(alignment: .leading, spacing: Metric.m) {
                    PanelHeading(title: "What this tide asks")
                    ForEach(Array(tide.objectives.enumerated()), id: \.offset) { _, objective in
                        ObjectiveRow(text: objective.text, progress: 0, met: false, compact: true)
                    }
                }

                HStack(spacing: Metric.xl) {
                    BriefStat(label: "Build", value: "\(Int(tide.buildSeconds))s")
                    BriefStat(label: "Flood", value: "\(Int(tide.floodSeconds))s")
                    BriefStat(label: "High water", value: String(format: "%.2f m", tide.highWater))
                    BriefStat(label: "Swell", value: String(format: "%.2f", tide.amplitude))
                }

                Button(action: onBegin) {
                    Text("Begin")
                        .font(.skDisplay(14, weight: .medium))
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metric.m)
                        .background { Capsule().fill(Palette.accent) }
                }
                .buttonStyle(.soft)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Metric.xl)
            .frame(maxWidth: 460)
            .skPanel()
            .padding(Metric.l)
        }
    }
}

struct BriefStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.skNumeric(15, weight: .medium))
            Text(label.uppercased())
                .font(.skDisplay(9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - Results

struct ResultsView: View {
    @Bindable var model: GameModel
    let grade: Grade
    @State private var revealed = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()

            VStack(spacing: Metric.l) {
                VStack(spacing: Metric.xs) {
                    Text(grade.letter)
                        .font(.skDisplay(64, weight: .ultraLight))
                        .foregroundStyle(Palette.accent)
                        .scaleEffect(revealed ? 1 : 0.7)
                        .opacity(revealed ? 1 : 0)
                    Text(grade.line)
                        .font(.skProse(13))
                        .lineSpacing(skProseSpacing)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.secondaryText)
                }

                MeterBar(value: min(grade.points / 100, 1), tint: Palette.accent, height: 8)
                    .frame(height: 8)

                HStack(spacing: Metric.xl) {
                    BriefStat(label: "Standing", value: "\(Int(model.result.standing))")
                    BriefStat(label: "Kept", value: "\(Int(model.result.kept * 100))%")
                    BriefStat(label: "Packed", value: String(format: "%.0f m³", model.result.packedVolume))
                    BriefStat(label: "Highest", value: String(format: "%.1f m", max(model.result.peakAbove, 0)))
                }

                Divider()

                VStack(alignment: .leading, spacing: Metric.s) {
                    ForEach(Array(model.tide.objectives.enumerated()), id: \.offset) { index, objective in
                        ObjectiveRow(text: objective.text,
                                     progress: objective.progress(model.result),
                                     met: index < model.objectivesMet.count && model.objectivesMet[index],
                                     compact: true)
                    }
                }

                HStack(spacing: Metric.m) {
                    Button {
                        model.start(mode: .tides, tide: model.tideNumber)
                    } label: {
                        Text("Again")
                            .font(.skDisplay(13, weight: .regular))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Metric.m)
                            .background { Capsule().fill(Palette.primaryText.opacity(0.08)) }
                    }
                    .buttonStyle(.soft)

                    if model.tideNumber < Tide.campaign.count {
                        Button {
                            model.start(mode: .tides, tide: model.tideNumber + 1)
                        } label: {
                            Text("Next tide")
                                .font(.skDisplay(13, weight: .medium))
                                .tracking(1.2)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.black.opacity(0.85))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Metric.m)
                                .background { Capsule().fill(Palette.accent) }
                        }
                        .buttonStyle(.soft)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.campaignProgress <= model.tideNumber)
                        .opacity(model.campaignProgress > model.tideNumber ? 1 : 0.4)
                    }
                }
            }
            .padding(Metric.xl)
            .frame(maxWidth: 460)
            .skPanel()
            .padding(Metric.l)
        }
        .onAppear {
            withAnimation(.skSlow.delay(0.15)) { revealed = true }
        }
    }
}
