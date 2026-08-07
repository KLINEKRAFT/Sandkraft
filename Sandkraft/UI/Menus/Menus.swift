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
// A title card, not a menu screen.
//
// This is the second rewrite, and the two things it was rewritten away from are
// worth naming because they are the two directions this kind of screen falls
// over in. The first version was a centred stack of frosted-glass cards with
// radio dots under a wordmark letterspaced past legibility — busy, generic,
// every element announcing itself. The second was so restrained it was dull: a
// left-aligned column of small grey type that read like a settings pane.
//
// What is here now takes the beach seriously as the picture:
//
//   · The mark sits high and the menu sits low, and the middle of the screen is
//     left alone. That gap is the whole design — it is where the sea is.
//   · The scrim is a vignette, dark at the top and bottom where the words are
//     and almost clear across the middle. Nothing is blurred.
//   · Everything is centred on one axis, so the eye falls down the middle of
//     the screen: mark, wordmark, modes, tides, Begin.
//   · A mode is a line of type. Selecting one turns it amber and writes a
//     sentence underneath. There is no card, no dot and no panel anywhere on
//     this screen.

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
        ZStack {
            vignette

            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        SandkraftLogo(markHeight: logoHeight(for: geo.size))
                            .padding(.top, geo.size.height * 0.07)
                            .skLegible()

                        // All of the slack lives here, which is what puts the
                        // mark at the top, the menu at the bottom, and the sea
                        // between them.
                        Spacer(minLength: Metric.xl)

                        menu
                            .frame(maxWidth: 520)
                            .padding(.horizontal, Metric.xl)

                        BrandMark(height: 18)
                            .padding(.top, Metric.xl)
                            .padding(.bottom, Metric.l)
                            .skLegible()
                    }
                    .frame(maxWidth: .infinity)
                    // Fills the screen when the content is shorter than it,
                    // which is what gives the Spacer something to expand into.
                    // Above that height it scrolls, so a short window or a
                    // large Dynamic Type size gets a scroll bar rather than a
                    // Begin button somewhere off the bottom edge.
                    .frame(minHeight: geo.size.height)
                }
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

    /// Dark at the top and bottom, nearly clear across the middle.
    ///
    /// The numbers are locations rather than an even ramp on purpose: the two
    /// dark ends have to reach exactly as far as the type does and then stop,
    /// because every millimetre past that is beach being covered up for nothing.
    private var vignette: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0.00),
                               .init(color: .black.opacity(0.30), location: 0.24),
                               .init(color: .black.opacity(0.04), location: 0.42),
                               .init(color: .black.opacity(0.38), location: 0.62),
                               .init(color: .black.opacity(0.88), location: 1.00)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// The mark scales with the window rather than sitting at one size. A
    /// ninety-point castle is a title on a Mac and most of an iPhone.
    private func logoHeight(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.155, 56), 110)
    }

    private var menu: some View {
        VStack(spacing: Metric.l) {
            if let storedBeach, let onContinue {
                ContinueRow(beach: storedBeach, action: onContinue)
            }

            modes

            if selectedMode == .tides {
                TidePicker(progress: model.campaignProgress) { number in
                    onStart(.tides, number)
                }
                .transition(.opacity)
            }

            actions
        }
        .animation(.skSnap, value: selectedMode)
    }

    /// Three lines of type. The selected one is amber and writes a sentence
    /// underneath itself — which is the only thing on this screen that changes
    /// height, and the reason the sentence is under all three rather than
    /// inside the one it belongs to.
    private var modes: some View {
        VStack(spacing: Metric.s) {
            ForEach(GameMode.allCases) { mode in
                ModeLine(mode: mode,
                         selected: selectedMode == mode,
                         progress: mode == .tides ? model.campaignProgress : nil) {
                    withAnimation(.skSnap) { selectedMode = mode }
                }
            }

            Text(selectedMode.longDescription)
                .font(.skProse(12))
                .lineSpacing(skProseSpacing - 2)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
                .padding(.top, Metric.xs)
                .skLegible()
        }
    }

    /// Begin, and two words. Begin is missing under Nine Tides on purpose:
    /// there, the tide you press *is* the begin button, and a second one would
    /// only raise the question of which tide it meant.
    private var actions: some View {
        VStack(spacing: Metric.m) {
            if selectedMode != .tides {
                Button {
                    onStart(selectedMode, 1)
                } label: {
                    Text("Begin")
                        .font(.skDisplay(15, weight: .medium))
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .padding(.horizontal, Metric.xxxl)
                        .padding(.vertical, Metric.m)
                        .background { Capsule().fill(Palette.accent) }
                }
                .buttonStyle(.soft)
                .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: Metric.xl) {
                if let onResume {
                    TextAction("Resume", shortcut: .cancelAction, action: onResume)
                }
                TextAction("Field Notes") { showingFieldNotes = true }
            }
        }
    }
}

/// The beach you were working on last time, offered back.
///
/// Above the modes rather than beside Begin, because it is not a fourth mode
/// and it is not the same kind of decision: the three below are *what to play*,
/// and this is *carry on*. It says when and which mode, because "Continue" on
/// its own asks the player to remember something they have had a day to forget.
struct ContinueRow: View {
    let beach: BeachHeader
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("Continue")
                    .font(.skDisplay(15, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Palette.accent)
                Text("\(beach.mode.title) · \(beach.savedAt.formatted(.relative(presentation: .named)))")
                    .font(.skProse(11))
                    .foregroundStyle(Palette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metric.s)
            .contentShape(Rectangle())
            .skLegible()
        }
        .buttonStyle(.soft)
        .accessibilityLabel("Continue the beach you were working on")
        .accessibilityValue("\(beach.mode.title), saved \(beach.savedAt.formatted(.relative(presentation: .named)))")
    }
}

/// A menu item that looks like a menu item: a word you can press. The press
/// feedback is the whole of the affordance, and it is enough.
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
                .padding(.horizontal, Metric.s)
                .contentShape(Rectangle())
                .skLegible()
        }
        .buttonStyle(.soft)
        // Applied to the button itself rather than to a wrapper, because that
        // is the only placement the modifier documents.
        .keyboardShortcut(shortcut)
    }
}

/// A mode, as a centred line of type.
///
/// The tap target is the full width of the column rather than the width of the
/// word, so "Rising" — six characters — is not a harder thing to press than
/// "Open Shore".
struct ModeLine: View {
    let mode: GameMode
    let selected: Bool
    let progress: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metric.s) {
                Text(mode.title)
                    .font(.skDisplay(17, weight: selected ? .medium : .regular))
                    .tracking(3)
                    .textCase(.uppercase)
                    .foregroundStyle(selected ? Palette.accent
                                              : Palette.primaryText.opacity(0.62))
                if let progress, progress > 1 {
                    Text("\(min(progress, Tide.campaign.count))/\(Tide.campaign.count)")
                        .font(Typeface.font(10, .regular))
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metric.xs)
            .contentShape(Rectangle())
            .skLegible()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Nine numbers, centred, naming only the one you are pointing at.
///
/// The grid of nine labelled tiles this replaced was the single largest object
/// on the title screen — nine panels, nine names set in ten-point type nobody
/// read, and a heading and a caption above them explaining what a numbered list
/// is. The tide's name is worth exactly one line, and only for the tide the
/// pointer is on.
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
        VStack(spacing: Metric.s) {
            // A grid rather than an HStack, and adaptive rather than fixed at
            // nine. Nine forty-two-point circles is 450 points of row, and an
            // iPhone in portrait has about 330 to give — so on a Mac this is
            // one row of nine and on a phone it wraps to two, without either
            // being a special case or a horizontal scroller nobody discovers.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 42), spacing: Metric.s)],
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
                            // forty-four, the gap makes up the difference, and
                            // a number you have to aim at is a number you press
                            // by accident.
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
            .frame(maxWidth: 460)

            if let tide = captionTide {
                Text("\(tide.number). \(tide.name)")
                    .font(.skProse(12))
                    .foregroundStyle(Palette.secondaryText)
                    // A floor, not a fixed height: it stops the row below
                    // hopping as the pointer moves along the numbers, without
                    // clipping the line at the larger Dynamic Type sizes.
                    .frame(minHeight: 18)
                    .skLegible()
            }
        }
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
