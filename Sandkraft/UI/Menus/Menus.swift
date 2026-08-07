//
//  Menus.swift
//  Sandkraft
//
//  The title screen, the card before a tide, and the card after one.
//
//  All three are typographic. There is no artwork behind them because there does
//  not need to be: the beach is already rendering behind them, at whatever time
//  of day the coming tide is set at, and a still image would be a downgrade.
//

import Foundation
import SwiftUI

// MARK: - Title
//
// This screen has been rewritten once already, and the thing it was rewritten
// away from is worth naming, because it is the default any interface drifts
// toward when nobody is watching: a centred column of frosted-glass cards, each
// with a radio dot on the right, under a wordmark letterspaced so wide it had
// to be nudged sideways to look centred. Every element announcing itself.
//
// What replaced it is one left-aligned column against a scrim. The rules:
//
//   · The beach is the picture. The interface does not compete with it, and it
//     does not blur it into a backdrop either — the sand behind this screen is
//     the sand you are about to work.
//   · One thing is a button. Begin. Everything else is text you can press,
//     which is what a menu item has always been.
//   · A mode is a line in a list. Not a card, not a tile, not a panel. Three
//     lines, a hairline between them, and the one you are on is the one wearing
//     the accent.
//   · Nothing is letterspaced past the point of being a word.

struct TitleView: View {
    @Bindable var model: GameModel
    /// The autosaved beach waiting on disk, if there is one this session can
    /// load. Nil hides the Continue line entirely — an offer that might fail is
    /// worse than no offer.
    var storedBeach: BeachHeader?
    /// Nil until a session exists. When it does, the title becomes a screen you
    /// can back out of rather than a door that only opens one way — which is
    /// what makes the Title button in the play view safe to press.
    var onResume: (() -> Void)?
    var onContinue: (() -> Void)?
    var onStart: (GameMode, Int) -> Void

    @State private var selectedMode: GameMode = .shore
    @State private var showingFieldNotes = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A scrim rather than a panel. It holds at full strength across the
            // column and is gone by two-thirds of the way over, so the beach is
            // still a beach — which a full-screen sheet of frosted glass is not.
            // Stops rather than evenly-spaced colours, because on a phone the
            // column is most of the width and an even fade would put the ends of
            // every line over clear sky.
            LinearGradient(stops: [.init(color: .black.opacity(0.74), location: 0.00),
                                   .init(color: .black.opacity(0.70), location: 0.42),
                                   .init(color: .black.opacity(0.00), location: 0.92)],
                           startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            ScrollView(.vertical, showsIndicators: false) {
                column
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(.horizontal, Metric.xxl)
                    .padding(.vertical, Metric.xxl)
                    // The 460 cap centres itself in whatever it is given unless
                    // it is told otherwise, and a title screen that drifts to
                    // the middle of a wide Mac window is the centred layout this
                    // was rewritten away from, arrived at by accident.
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sandkraft")
                .font(.skDisplay(40, weight: .regular))
                .tracking(-0.5)
                .skLegible()

            Text("Dry sand cannot stand.")
                .font(.skProse(13))
                .foregroundStyle(Palette.secondaryText)
                .padding(.top, Metric.s)
                .skLegible()

            if let storedBeach, let onContinue {
                ContinueRow(beach: storedBeach, action: onContinue)
                    .padding(.top, Metric.xl)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(GameMode.allCases.enumerated()), id: \.element) { index, mode in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 1)
                    }
                    ModeRow(mode: mode,
                            selected: selectedMode == mode,
                            progress: mode == .tides ? model.campaignProgress : nil) {
                        withAnimation(.skSnap) { selectedMode = mode }
                    }
                }
            }
            .padding(.top, Metric.xxl)

            if selectedMode == .tides {
                TidePicker(progress: model.campaignProgress) { number in
                    onStart(.tides, number)
                }
                .padding(.top, Metric.l)
                .transition(.opacity)
            }

            actions
                .padding(.top, Metric.xl)

            BrandMark(height: 20)
                .padding(.top, Metric.xxxl)
                .skLegible()
        }
        .animation(.skSnap, value: selectedMode)
    }

    /// One filled button and two quiet ones. Begin is missing under Nine Tides
    /// on purpose: there, the tide you press *is* the begin button, and a second
    /// one would only raise the question of which tide it meant.
    private var actions: some View {
        HStack(spacing: Metric.xl) {
            if selectedMode != .tides {
                Button {
                    onStart(selectedMode, 1)
                } label: {
                    Text("Begin")
                        .font(.skDisplay(14, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, Metric.xl)
                        .padding(.vertical, Metric.m)
                        .background { Capsule().fill(Palette.accent) }
                }
                .buttonStyle(.soft)
                .keyboardShortcut(.defaultAction)
            }

            if let onResume {
                TextAction("Resume", shortcut: .cancelAction, action: onResume)
            }

            TextAction("Field Notes") { showingFieldNotes = true }

            Spacer(minLength: 0)
        }
    }
}

/// The beach you were working on last time, offered back.
///
/// Above the mode list rather than beside Begin, because it is not a fourth
/// mode and it is not the same kind of decision: the three below are *what to
/// play*, and this is *carry on*. It says when and it says which mode, because
/// "Continue" on its own asks the player to remember something they have had a
/// day to forget.
struct ContinueRow: View {
    let beach: BeachHeader
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metric.s) {
                Text("Continue")
                    .font(.skDisplay(15, weight: .medium))
                    .foregroundStyle(Palette.accent)
                Text("\(beach.mode.title) · \(beach.savedAt.formatted(.relative(presentation: .named)))")
                    .font(.skProse(12))
                    .foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Metric.s)
            .contentShape(Rectangle())
            .skLegible()
        }
        .buttonStyle(.soft)
        .accessibilityLabel("Continue the beach you were working on")
        .accessibilityValue("\(beach.mode.title), saved \(beach.savedAt.formatted(.relative(presentation: .named)))")
    }
}

/// A menu item that looks like a menu item: a word you can press. The underline
/// on press is the whole of the affordance, and it is enough.
struct TextAction: View {
    let title: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    init(_ title: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.skProse(13))
                .foregroundStyle(Palette.primaryText.opacity(0.85))
                // The tap target is bigger than the word. Without this a
                // thirteen-point line of text is a nine-point target.
                .padding(.vertical, Metric.s)
                .contentShape(Rectangle())
                .skLegible()
        }
        .buttonStyle(.soft)
        // Applied to the button itself rather than to a wrapper, because that
        // is the only placement the modifier documents.
        .keyboardShortcut(shortcut)
    }
}

/// A mode, as a line. The accent bar on the left is the only selection mark —
/// no dot, no tick, no card behind it — and the description under the name
/// appears only for the line you are on, so two of the three are always one
/// line tall.
struct ModeRow: View {
    let mode: GameMode
    let selected: Bool
    let progress: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metric.m) {
                Rectangle()
                    .fill(selected ? Palette.accent : Color.clear)
                    .frame(width: 2)

                VStack(alignment: .leading, spacing: Metric.xs) {
                    HStack(spacing: Metric.s) {
                        Text(mode.title)
                            .font(.skDisplay(19, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? Palette.primaryText
                                                      : Palette.primaryText.opacity(0.7))
                        if let progress, progress > 1 {
                            Text("tide \(min(progress, Tide.campaign.count)) of \(Tide.campaign.count)")
                                .font(Typeface.font(10, .regular))
                                .foregroundStyle(Palette.accent)
                        }
                    }

                    Text(selected ? mode.longDescription : mode.subtitle)
                        .font(.skProse(12))
                        .lineSpacing(skProseSpacing - 2)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, Metric.m)
            .contentShape(Rectangle())
            .skLegible()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Nine numbers in a row, and the name of the one you are about to press.
///
/// The grid of nine labelled tiles this replaced was the single largest object
/// on the title screen — nine panels, nine names set in ten-point type nobody
/// read, and a heading and a caption above them explaining what a numbered list
/// is. The tide's name is worth exactly one line, and only for the tide the
/// pointer is actually on.
struct TidePicker: View {
    /// How far the campaign has been played. Passed in rather than read off the
    /// model, because that is the only thing this view needs from it.
    let progress: Int
    var onPick: (Int) -> Void

    @State private var hovered: Int?

    private var captionTide: Tide? {
        let number = hovered ?? min(progress, Tide.campaign.count)
        return Tide.campaign.first { $0.number == number }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.s) {
            // A grid rather than an HStack, and adaptive rather than fixed at
            // nine. Nine forty-two-point circles is 450 points of row, and an
            // iPhone in portrait has about 330 to give — so on a Mac this is one
            // row of nine and on a phone it wraps to two, without either of them
            // being a special case or a horizontal scroller nobody discovers.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: Metric.s)],
                      alignment: .leading,
                      spacing: Metric.s) {
                ForEach(Tide.campaign) { tide in
                    let unlocked = tide.number <= progress
                    Button {
                        if unlocked { onPick(tide.number) }
                    } label: {
                        Text("\(tide.number)")
                            .font(.skNumeric(15, weight: .medium))
                            .foregroundStyle(unlocked ? Palette.primaryText
                                                      : Palette.secondaryText.opacity(0.35))
                            // Forty-two rather than the thirty-two this looks
                            // like it wants to be: `Metric.touchTarget` is
                            // forty-four, the gap makes up the difference, and a
                            // number you have to aim at is a number you press by
                            // accident.
                            .frame(width: 42, height: 42)
                            .background {
                                Circle()
                                    .fill(Palette.accent.opacity(hovered == tide.number ? 0.22 : 0))
                                    .overlay {
                                        Circle().strokeBorder(
                                            unlocked ? Color.white.opacity(0.22) : Color.white.opacity(0.07),
                                            lineWidth: 1)
                                    }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.soft)
                    .disabled(!unlocked)
                    .onHover { inside in hovered = inside ? tide.number : nil }
                    .accessibilityLabel("Tide \(tide.number), \(tide.name)")
                    .accessibilityHint(unlocked ? "Begin this tide" : "Locked until you reach it")
                }
            }

            if let tide = captionTide {
                Text("\(tide.number). \(tide.name)")
                    .font(.skProse(12))
                    .foregroundStyle(Palette.secondaryText)
                    // A floor, not a fixed height: it stops the row below hopping
                    // as the pointer moves along the numbers, without clipping the
                    // line at the larger Dynamic Type sizes.
                    .frame(minHeight: 18, alignment: .leading)
                    .skLegible()
            }
        }
        .animation(.skSnap, value: hovered)
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
