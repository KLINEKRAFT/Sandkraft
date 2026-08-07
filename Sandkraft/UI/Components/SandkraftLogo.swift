//
//  SandkraftLogo.swift
//  Sandkraft
//
//  The game's own mark: a castle, drawn as one filled path.
//
//  It is the app icon's castle rather than a second idea about what this game
//  looks like. An icon and a title screen showing two different castles is the
//  most common way a small project ends up looking like it was assembled rather
//  than designed, and the cost of avoiding it is nil — the shape is simple
//  enough to state twice.
//
//  Drawn rather than bundled, for the same reason every other icon in this
//  project is: a path scales to any size on any display, inherits the current
//  colour, and cannot go missing from a build. There is one asset in this app
//  and it is the app icon, because that one has to be a PNG.
//
//  **Filled, not stroked.** Every other glyph here is a line drawing at 20-odd
//  points, where a stroke is what makes it legible. This is set at ninety and
//  wants to read as a silhouette from across a room, which is what a mark is
//  for. The door is a hole in the fill, not a shape laid over it, so the mark
//  works on any background — including the beach, which is a different colour
//  every hour of the day.
//

import SwiftUI

/// The castle, in a 100 × 100 box.
///
/// Everything is stated in that box and scaled to whatever rect it is given, so
/// the proportions cannot drift between the title screen and anywhere else it
/// ends up.
struct CastleMark: Shape {

    func path(in rect: CGRect) -> Path {
        var p = Path()

        let side = min(rect.width, rect.height)
        let ox = rect.midX - side / 2
        let oy = rect.midY - side / 2
        let s = side / 100

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + y * s)
        }

        // Three merlons and two notches, spanning x0…x1. The proportions are a
        // fraction of the span rather than absolute, so the narrow towers and
        // the wide keep are crenellated to the same rhythm instead of the keep
        // looking like a different building.
        func crenellate(from x0: CGFloat, to x1: CGFloat, top: CGFloat, notch: CGFloat) {
            let w = x1 - x0
            let m = w * 0.26          // merlon
            let g = w * 0.11          // gap
            p.addLine(to: pt(x0, top))
            p.addLine(to: pt(x0 + m, top))
            p.addLine(to: pt(x0 + m, top + notch))
            p.addLine(to: pt(x0 + m + g, top + notch))
            p.addLine(to: pt(x0 + m + g, top))
            p.addLine(to: pt(x0 + 2 * m + g, top))
            p.addLine(to: pt(x0 + 2 * m + g, top + notch))
            p.addLine(to: pt(x0 + 2 * m + 2 * g, top + notch))
            p.addLine(to: pt(x0 + 2 * m + 2 * g, top))
            p.addLine(to: pt(x1, top))
        }

        // The silhouette: left tower, keep, right tower, and the wall between
        // them. One subpath, walked clockwise from the bottom-left.
        p.move(to: pt(8, 96))
        crenellate(from: 8, to: 33, top: 48, notch: 7)
        p.addLine(to: pt(33, 62))
        p.addLine(to: pt(38, 62))
        crenellate(from: 38, to: 62, top: 26, notch: 7)
        p.addLine(to: pt(62, 62))
        p.addLine(to: pt(67, 62))
        crenellate(from: 67, to: 92, top: 48, notch: 7)
        p.addLine(to: pt(92, 96))
        p.closeSubpath()

        // The door, as its own subpath inside the silhouette. Filled even-odd,
        // so this subtracts rather than adds.
        p.move(to: pt(44, 96))
        p.addLine(to: pt(44, 82))
        p.addQuadCurve(to: pt(56, 82), control: pt(50, 73))
        p.addLine(to: pt(56, 96))
        p.closeSubpath()

        // The pole, stopping exactly on the merlon it stands on. A pole that
        // overlapped the keep would cancel against it under even-odd and punch
        // a notch in the battlement.
        p.move(to: pt(48.8, 4))
        p.addLine(to: pt(51.2, 4))
        p.addLine(to: pt(51.2, 26))
        p.addLine(to: pt(48.8, 26))
        p.closeSubpath()

        // The pennant, hung off the right edge of the pole and touching it.
        p.move(to: pt(51.2, 5))
        p.addLine(to: pt(73, 13))
        p.addLine(to: pt(51.2, 21))
        p.closeSubpath()

        return p
    }
}

/// The full lockup: the castle over the wordmark.
///
/// One size knob. The wordmark and its letterspacing are both fractions of the
/// mark's height, so the lockup is the same drawing at every size rather than
/// three numbers that have to be re-tuned every time it moves.
struct SandkraftLogo: View {
    var markHeight: CGFloat = 92
    var tint: Color = Palette.primaryText
    var markTint: Color = Palette.accent

    private var wordSize: CGFloat { markHeight * 0.30 }

    var body: some View {
        VStack(spacing: markHeight * 0.16) {
            CastleMark()
                // Even-odd is what makes the door a hole. Without it the door
                // subpath fills solid and the castle is a lump.
                .fill(markTint, style: FillStyle(eoFill: true))
                .frame(width: markHeight, height: markHeight)

            Text("SANDKRAFT")
                .font(.skDisplay(wordSize, weight: .medium))
                // Letterspacing on a wordmark is not the same move as
                // letterspacing a paragraph, which is why this is here and not
                // anywhere else in the app: nine letters set once, at size, as
                // a piece of drawing. The trailing space tracking adds after
                // the final T is taken back on the leading edge so the word is
                // actually centred rather than merely centred-ish.
                .tracking(wordSize * 0.20)
                .padding(.leading, wordSize * 0.20)
                .foregroundStyle(tint)
        }
        .accessibilityElement()
        .accessibilityLabel("Sandkraft")
        .accessibilityAddTraits(.isHeader)
    }
}
