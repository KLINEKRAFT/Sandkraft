//
//  Components.swift
//  Sandkraft
//
//  The small pieces the play interface is assembled from. Everything here is
//  stateless and takes its values as plain parameters, so each one can be
//  previewed on its own and none of them can reach into the game model.
//

import SwiftUI

// MARK: - Icon button

/// The single button shape in the game. Circular, material-backed, and always
/// at least a 44-point target however small the glyph inside it is.
struct IconButton: View {
    let glyph: Glyph
    var label: String
    var size: CGFloat = 44
    var glyphSize: CGFloat = 20
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlyphView(glyph: glyph, size: glyphSize, weight: 1.7)
                .foregroundStyle(prominent ? Color.black.opacity(0.82) : Palette.primaryText)
                .frame(width: size, height: size)
                .background {
                    Circle().fill(prominent ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.regularMaterial))
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(prominent ? 0 : 0.18), lineWidth: 0.75)
                }
        }
        .buttonStyle(.soft)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

// MARK: - Meters

/// A horizontal fill. Used for the pail and for objective progress, and nowhere
/// else — a game with four different bar styles has no bar style.
struct MeterBar: View {
    var value: Double                 // 0…1
    var tint: Color = Palette.accent
    var height: CGFloat = 6
    var track: Double = 0.16

    /// Explicit CGFloat throughout. The implicit CGFloat/Double bridge would
    /// compile this inline, but every such site adds real work to type inference
    /// — and one of them has already cost a build.
    private func filledWidth(in available: CGFloat) -> CGFloat {
        let fraction = CGFloat(min(max(value, 0), 1))
        let filled = available * fraction
        // A capsule narrower than it is tall renders as a sliver; below the
        // threshold show nothing at all rather than a stub.
        return value > 0.001 ? max(filled, height) : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.primaryText.opacity(track))
                Capsule()
                    .fill(tint)
                    .frame(width: filledWidth(in: geo.size.width))
            }
        }
        .frame(height: height)
        .animation(.skSnap, value: value)
    }
}

/// How much sand you are carrying, and how wet it is.
///
/// These two facts belong together and are almost always shown apart, which is
/// why so many players pour a bucket of bone-dry sand onto a tower they have
/// just spent a minute wetting. Wetness is the fill colour, not a second widget.
struct PailMeter: View {
    var fraction: Double
    var moisture: Double
    var isEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.xs) {
            HStack(spacing: Metric.s) {
                GlyphView(glyph: .pour, size: 15, weight: 1.7)
                    .foregroundStyle(Palette.secondaryText)
                Text(isEmpty ? "Pail empty" : Palette.moistureLabel(moisture))
                    .font(.skLabel)
                    .foregroundStyle(isEmpty ? Palette.secondaryText : Palette.primaryText)
                Spacer(minLength: Metric.s)
                Text("\(Int(fraction * 100))")
                    .font(.skNumeric(13, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .monospacedDigit()
            }
            MeterBar(value: fraction, tint: isEmpty ? Palette.secondaryText.opacity(0.4) : Palette.moisture(moisture))
        }
        .frame(minWidth: 132)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pail")
        .accessibilityValue(isEmpty ? "Empty" : "\(Int(fraction * 100)) percent full, \(Palette.moistureLabel(moisture))")
    }
}

/// The moisture of the sand directly under the cursor. The single most useful
/// number on the screen, and the reason a player stops guessing.
struct MoistureReadout: View {
    var moisture: Double
    var packing: Double
    var valid: Bool

    var body: some View {
        HStack(spacing: Metric.s) {
            ZStack {
                Circle()
                    .strokeBorder(Palette.primaryText.opacity(0.14), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(valid ? moisture : 0))
                    .stroke(Palette.moisture(moisture),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .fill(Palette.moisture(moisture).opacity(valid ? 0.9 : 0.15))
                    .frame(width: 8, height: 8)
            }
            .frame(width: 28, height: 28)
            .animation(.skSnap, value: moisture)

            VStack(alignment: .leading, spacing: 1) {
                Text(valid ? Palette.moistureLabel(moisture) : "—")
                    .font(.skLabel)
                Text(valid ? "packed \(Int(packing * 100))%" : "no sand under cursor")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sand under cursor")
        .accessibilityValue(valid
                            ? "\(Palette.moistureLabel(moisture)), packed \(Int(packing * 100)) percent"
                            : "Nothing under the cursor")
    }
}

// MARK: - Tide clock

/// A ring that empties as the phase runs out, with the phase name inside it.
///
/// Deliberately not a countdown in seconds. A number counting down makes the
/// last ten seconds of a build window feel like an exam; a ring closing makes it
/// feel like a tide.
struct TideClock: View {
    var progress: Double            // 0 at the start of the phase, 1 at the end
    var phaseName: String
    var detail: String
    var urgent: Bool

    private var tint: Color {
        urgent ? Palette.tide : Palette.accent
    }

    var body: some View {
        HStack(spacing: Metric.m) {
            ZStack {
                Circle().strokeBorder(Palette.primaryText.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(1 - min(max(progress, 0), 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                if urgent {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .scaleEffect(urgent ? 1.0 : 0.6)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(phaseName)
                    .font(.skLabel)
                    .foregroundStyle(urgent ? tint : Palette.primaryText)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(phaseName)
        .accessibilityValue(detail)
    }
}

// MARK: - Objectives

struct ObjectiveRow: View {
    var text: String
    var progress: Double
    var met: Bool
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: Metric.m) {
            ZStack {
                Circle()
                    .strokeBorder(met ? Palette.good : Palette.primaryText.opacity(0.22), lineWidth: 1.6)
                    .frame(width: 18, height: 18)
                if met {
                    Path { p in
                        p.move(to: CGPoint(x: 4.5, y: 9.5))
                        p.addLine(to: CGPoint(x: 8, y: 13))
                        p.addLine(to: CGPoint(x: 13.5, y: 5.5))
                    }
                    .stroke(Palette.good, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(text)
                    .font(compact ? .system(size: 12) : .system(.subheadline))
                    .foregroundStyle(met ? Palette.secondaryText : Palette.primaryText)
                    .strikethrough(met, color: Palette.secondaryText)
                if !met && !compact {
                    MeterBar(value: progress, tint: Palette.accent.opacity(0.75), height: 3)
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.skSnap, value: met)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityValue(met ? "Met" : "\(Int(progress * 100)) percent")
    }
}

// MARK: - Chips

/// A tool in the rail. Glyph over label, with the accent doing the selection.
struct ToolChip: View {
    let tool: Tool
    var selected: Bool
    var enabled: Bool = true
    var showsShortcut = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                GlyphView(glyph: tool.glyph, size: 24, weight: selected ? 1.9 : 1.6)
                Text(tool.name)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.black.opacity(0.86) : Palette.primaryText)
            .frame(width: 60, height: 56)
            .background {
                RoundedRectangle(cornerRadius: Metric.radiusSmall + 4, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.clear))
            }
            .overlay(alignment: .topTrailing) {
                if showsShortcut {
                    Text(String(tool.shortcut))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(selected ? Color.black.opacity(0.45) : Palette.secondaryText)
                        .padding(3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Metric.radiusSmall + 4, style: .continuous))
        }
        .buttonStyle(.soft)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .animation(.skSnap, value: selected)
        .accessibilityLabel(tool.name)
        .accessibilityHint(tool.summary)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A square swatch for a mould, adornment or look.
struct GlyphChip: View {
    let glyph: Glyph
    let title: String
    var subtitle: String?
    var selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Metric.xs) {
                GlyphView(glyph: glyph, size: 30, weight: 1.5)
                    .frame(height: 34)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(height: 22)
                }
            }
            .foregroundStyle(selected ? Color.black.opacity(0.86) : Palette.primaryText)
            .padding(.vertical, Metric.s)
            .padding(.horizontal, Metric.xs)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Metric.radiusMedium, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Palette.primaryText.opacity(0.06)))
            }
            .contentShape(RoundedRectangle(cornerRadius: Metric.radiusMedium, style: .continuous))
        }
        .buttonStyle(.soft)
        .animation(.skSnap, value: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Layout helpers

/// A section heading inside a panel. One weight, one colour, one size.
struct PanelHeading: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.skLabel)
                .foregroundStyle(Palette.secondaryText)
            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The floating hint that appears when a tool is selected and disappears once
/// you have used it. Teaching that removes itself.
struct HintBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.primaryText)
            .padding(.horizontal, Metric.m)
            .padding(.vertical, Metric.s)
            .skPanel(radius: Metric.radiusMedium, material: .thinMaterial)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
