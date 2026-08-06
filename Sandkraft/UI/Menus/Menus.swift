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

                VStack(spacing: Metric.s) {
                    Text("SANDKRAFT")
                        .font(.system(size: 44, weight: .light, design: .serif))
                        .tracking(10)
                        .skLegible()
                    Text("A sandcastle simulator")
                        .font(.skSerif(15))
                        .italic()
                        .foregroundStyle(Palette.secondaryText)
                        .skLegible()
                }
                .padding(.bottom, Metric.xxl)

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

                HStack(spacing: Metric.m) {
                    Button {
                        showingFieldNotes = true
                    } label: {
                        Label("Field Notes", systemImage: "book")
                            .font(.system(size: 14, weight: .medium))
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
                                .font(.system(size: 16, weight: .semibold))
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
                            .font(.skSerif(20, weight: .semibold))
                        if let progress, progress > 1 {
                            Text("tide \(min(progress, 9)) of 9")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                                .padding(.horizontal, Metric.s)
                                .padding(.vertical, 2)
                                .background { Capsule().fill(Palette.accent.opacity(0.15)) }
                        }
                    }
                    Text(selected ? mode.longDescription : mode.subtitle)
                        .font(.system(size: 13))
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
                                .font(.system(size: 10))
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
                        .font(.skSerif(30, weight: .semibold))
                        .multilineTextAlignment(.center)
                }

                Text(tide.epigraph)
                    .font(.skSerif(16))
                    .italic()
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
                        .font(.system(size: 16, weight: .semibold))
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
            Text(value).font(.skNumeric(15, weight: .semibold))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
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
                        .font(.system(size: 66, weight: .light, design: .serif))
                        .foregroundStyle(Palette.accent)
                        .scaleEffect(revealed ? 1 : 0.7)
                        .opacity(revealed ? 1 : 0)
                    Text(grade.line)
                        .font(.skSerif(16))
                        .italic()
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
                            .font(.system(size: 15, weight: .medium))
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
                                .font(.system(size: 15, weight: .semibold))
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
