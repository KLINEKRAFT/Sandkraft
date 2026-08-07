//
//  Glyphs.swift
//  Sandkraft
//
//  Every icon in the game, drawn as a stroked path in a 24×24 grid.
//
//  Not SF Symbols. Two reasons, and the first is the honest one: there is no SF
//  Symbol for "pack sand down with the flat of your hand", and the near-misses
//  you end up choosing instead quietly teach the player the wrong verb. The
//  second is that a symbol that does not exist on an older OS renders as nothing
//  at all, which is a blank tool button in a shipping build.
//
//  These are drawn once, scale to any size, inherit the current foreground
//  colour, and are one file to audit.
//

import SwiftUI

enum Glyph: String, Hashable {
    // Tools
    case dig, pour, drip, mould, wall
    case pack, wet, carve, level, place

    // Moulds
    case mTurret, mKeep, mGate, mStar, mZiggurat, mSpire, mScallop, mFish, mCrab, mStarfish

    // Adornments
    case pennant, parasol, pinwheel, lantern, pailSpade, boat, shell, starfish, driftwood, kelp, bottle, cairn

    // Interface
    case undo, redo, camera, tide, sun, cloud, layers, settings, close, play, pause, restart, info
    case expand, collapse
}

/// Draws a glyph into a 24×24 box, scaled to fit whatever rect it is given.
struct GlyphShape: Shape {
    let glyph: Glyph

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let originX = rect.midX - side / 2
        let originY = rect.midY - side / 2

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }
        func move(_ x: CGFloat, _ y: CGFloat) { p.move(to: pt(x, y)) }
        func line(_ x: CGFloat, _ y: CGFloat) { p.addLine(to: pt(x, y)) }
        func curve(_ x: CGFloat, _ y: CGFloat, _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat) {
            p.addCurve(to: pt(x, y), control1: pt(c1x, c1y), control2: pt(c2x, c2y))
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            p.addEllipse(in: CGRect(x: originX + (cx - r) * scale, y: originY + (cy - r) * scale,
                                    width: r * 2 * scale, height: r * 2 * scale))
        }
        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
            p.addEllipse(in: CGRect(x: originX + (cx - rx) * scale, y: originY + (cy - ry) * scale,
                                    width: rx * 2 * scale, height: ry * 2 * scale))
        }

        switch glyph {

        // MARK: Tools

        case .dig:
            // A spade: handle, shaft, blade.
            move(12, 2); line(12, 5)
            move(9.4, 2); line(14.6, 2)
            move(12, 5); line(12, 13)
            move(8.6, 13); line(15.4, 13); line(12, 21); p.closeSubpath()

        case .pour:
            // A pail tipping, with sand falling out of it.
            move(4, 6); line(13, 6); line(11.4, 15.5)
            curve(8.6, 17, 11.1, 16.7, 9.9, 17)
            line(7.2, 17); curve(5.6, 15.5, 6.3, 17, 5.7, 16.4)
            p.closeSubpath()
            move(5.6, 6); curve(11.4, 6, 5.9, 3.2, 11.1, 3.2)
            move(15.5, 12); line(17, 15); move(18, 11); line(19.6, 14.5)
            move(16.4, 17.5); line(17.6, 20)

        case .drip:
            // A single drop falling onto a knobbled spire.
            move(12, 2)
            curve(14, 6, 13.4, 3.6, 14, 4.8)
            curve(10, 6, 14, 8.2, 10, 8.2)
            curve(12, 2, 10, 4.8, 10.6, 3.6)
            move(8.6, 21)
            curve(10.2, 11, 8.9, 17, 9.6, 13.4)
            move(15.4, 21)
            curve(13.8, 11, 15.1, 17, 14.4, 13.4)
            move(9.6, 15.6); line(14.4, 15.6)
            move(10.3, 12.4); line(13.7, 12.4)
            move(6.5, 21); line(17.5, 21)

        case .mould:
            // A bucket, upside down, with the turret it turns out.
            move(6, 20); line(7.6, 8); line(16.4, 8); line(18, 20)
            move(7.6, 8); line(7.6, 5.2); line(16.4, 5.2); line(16.4, 8)
            move(9.6, 5.2); line(9.6, 3.4); move(12, 5.2); line(12, 3)
            move(14.4, 5.2); line(14.4, 3.4)
            move(4.5, 20); line(19.5, 20)

        case .wall:
            // A crenellated berm running across the frame.
            move(2.5, 20); line(21.5, 20)
            move(4, 20); line(4, 13); line(20, 13); line(20, 20)
            move(4, 13); line(4, 10); line(7.2, 10); line(7.2, 13)
            move(10.4, 13); line(10.4, 10); line(13.6, 10); line(13.6, 13)
            move(16.8, 13); line(16.8, 10); line(20, 10); line(20, 13)

        case .pack:
            // A flat hand pressing down, with the sand compressing under it.
            move(4.5, 12.5); line(19.5, 12.5)
            move(7, 12.5); line(7, 7.4)
            curve(9.2, 5.2, 7, 6.2, 7.9, 5.2)
            curve(11.4, 7.4, 10.5, 5.2, 11.4, 6.2)
            move(11.4, 7.4); line(11.4, 6.2)
            curve(13.6, 4, 11.4, 5, 12.3, 4)
            curve(15.8, 6.2, 14.9, 4, 15.8, 5)
            line(15.8, 12.5)
            move(5.5, 17); line(18.5, 17)
            move(4.2, 20.5); line(19.8, 20.5)

        case .wet:
            // A drop, with the meniscus that is doing all the work.
            move(12, 2.5)
            curve(18.5, 13.4, 15.6, 5.6, 18.5, 10.2)
            curve(5.5, 13.4, 18.5, 17, 5.5, 17)
            curve(12, 2.5, 5.5, 10.2, 8.4, 5.6)
            move(9.4, 13.6)
            curve(12, 16.4, 9.4, 15.2, 10.6, 16.4)

        case .carve:
            // A blade cutting a slot, with the cut edge left standing.
            move(15.2, 2.4); line(21.6, 8.8); line(11.4, 19); line(5, 12.6)
            p.closeSubpath()
            move(11.6, 6); line(18, 12.4)
            move(5.4, 12.9); line(2.6, 21.4); line(11.1, 18.6)

        case .level:
            // A straightedge with a bubble.
            move(2.5, 12); line(21.5, 12)
            move(2.5, 12); line(6, 8.6); move(2.5, 12); line(6, 15.4)
            move(21.5, 12); line(18, 8.6); move(21.5, 12); line(18, 15.4)
            move(12, 4.5); line(12, 8); move(12, 16); line(12, 19.5)

        case .place:
            // A star being set down, with the mark where it lands.
            move(12, 2.6); line(14.4, 8.6); line(20.8, 9.1); line(15.9, 13.3)
            line(17.4, 19.6); line(12, 16.2); line(6.6, 19.6); line(8.1, 13.3)
            line(3.2, 9.1); line(9.6, 8.6); p.closeSubpath()

        // MARK: Moulds

        case .mTurret:
            move(6, 21); line(6, 8); line(12, 3.5); line(18, 8); line(18, 21)
            move(6, 8); line(18, 8)
            move(8.4, 8); line(8.4, 5.6); move(12, 8); line(12, 4)
            move(15.6, 8); line(15.6, 5.6)

        case .mKeep:
            move(4, 21); line(4, 7); line(20, 7); line(20, 21)
            move(4, 7); line(4, 4); line(7, 4); line(7, 6); line(10, 6)
            line(10, 4); line(14, 4); line(14, 6); line(17, 6); line(17, 4)
            line(20, 4); line(20, 7)

        case .mGate:
            move(3, 21); line(3, 7); line(8, 7); line(8, 21)
            move(16, 21); line(16, 7); line(21, 7); line(21, 21)
            move(8, 21); line(8, 13); line(16, 13); line(16, 21)
            move(10.5, 21); line(10.5, 17)
            curve(13.5, 17, 10.5, 15.4, 13.5, 15.4)
            line(13.5, 21)

        case .mStar:
            move(12, 2.5); line(14.6, 8.8); line(21.4, 9.4); line(16.2, 13.9)
            line(17.8, 20.5); line(12, 17); line(6.2, 20.5); line(7.8, 13.9)
            line(2.6, 9.4); line(9.4, 8.8); p.closeSubpath()

        case .mZiggurat:
            move(2, 21); line(22, 21)
            move(4, 21); line(4, 17); line(20, 17)
            move(6.5, 17); line(6.5, 13); line(17.5, 13)
            move(9, 13); line(9, 9); line(15, 9)
            move(11, 9); line(11, 5.5); line(13, 5.5); line(13, 9)
            move(20, 17); line(20, 21); move(17.5, 13); line(17.5, 17)
            move(15, 9); line(15, 13)

        case .mSpire:
            move(12, 2); line(16.5, 21); line(7.5, 21); p.closeSubpath()
            move(9, 15); line(15, 15); move(10, 9); line(14, 9)

        case .mScallop:
            move(12, 20.5)
            curve(2.8, 11, 6, 20.5, 2.8, 15.5)
            curve(21.2, 11, 2.8, 1, 21.2, 1)
            curve(12, 20.5, 21.2, 15.5, 18, 20.5)
            move(12, 20.5); line(12, 3)
            move(8, 20.2); line(6, 4.6); move(16, 20.2); line(18, 4.6)

        case .mFish:
            move(20, 12)
            curve(11.6, 17.4, 17.4, 15.6, 14.6, 17.4)
            curve(4, 12, 8.6, 17.4, 6, 15.6)
            curve(11.6, 6.6, 6, 8.4, 8.6, 6.6)
            curve(20, 12, 14.6, 6.6, 17.4, 8.4)
            move(20, 12); line(23, 8.6); line(23, 15.4); p.closeSubpath()
            circle(8, 11, 0.9)

        case .mCrab:
            ellipse(12, 13.5, 5.5, 4)
            move(6, 8.5); line(3.6, 6.4)
            move(18, 8.5); line(20.4, 6.4)
            circle(3.2, 5.4, 1.5); circle(20.8, 5.4, 1.5)
            move(6.6, 16); line(3, 18); move(17.4, 16); line(21, 18)
            move(7.5, 12.5); line(3.5, 12); move(16.5, 12.5); line(20.5, 12)

        case .mStarfish:
            move(12, 3); line(14.4, 9.1); line(20.9, 9.5); line(16, 13.7)
            line(17.7, 20); line(12, 16.6); line(6.3, 20); line(8, 13.7)
            line(3.1, 9.5); line(9.6, 9.1); p.closeSubpath()
            circle(12, 12.5, 1)

        // MARK: Adornments

        case .pennant:
            move(6, 21); line(6, 3)
            move(6, 4); line(17, 4); line(14.5, 7.5); line(17, 11); line(6, 11)

        case .parasol:
            move(12, 12); line(12, 21); move(10.5, 21); line(13.5, 21)
            move(2.5, 12); curve(21.5, 12, 2.5, 2, 21.5, 2); p.closeSubpath()
            move(6.5, 12); curve(12, 2.5, 6.5, 6.5, 9, 2.5)
            curve(17.5, 12, 15, 2.5, 17.5, 6.5)

        case .pinwheel:
            move(12, 12); line(12, 21)
            circle(12, 12, 1.4)
            move(12, 10.6); curve(15.4, 4, 12, 6.6, 13, 4)
            curve(13.4, 11.3, 17.8, 4, 18, 8)
            move(13.4, 12.6); curve(20, 16, 17.4, 12.6, 20, 13.6)
            curve(12.7, 14, 20, 18.4, 16, 18.6)
            move(10.6, 12.6); curve(4, 9, 6.6, 12.6, 4, 11.6)
            curve(11.3, 10, 4, 5.4, 8, 5.2)

        case .lantern:
            move(12, 3); curve(17, 8, 14.8, 3, 17, 5.2)
            curve(15, 14, 17, 11, 15, 12)
            line(9, 14); curve(7, 8, 9, 12, 7, 11)
            curve(12, 3, 7, 5.2, 9.2, 3)
            move(10, 17); line(14, 17); move(10.5, 20); line(13.5, 20)

        case .pailSpade:
            move(4, 8); line(17, 8); line(15.6, 18.6)
            curve(13.6, 20.3, 15.4, 19.8, 14.6, 20.3)
            line(7.4, 20.3); curve(5.4, 18.6, 6.2, 20.3, 5.5, 19.6)
            p.closeSubpath()
            move(6, 8); curve(15, 8, 6.3, 3.5, 14.7, 3.5)
            move(19, 20); line(19, 9); move(16.5, 9); line(21.5, 9)

        case .boat:
            move(3, 17); line(21, 17); line(18.5, 21); line(5.5, 21); p.closeSubpath()
            move(12, 16); line(12, 3)
            move(12.8, 4.2); curve(19, 9.8, 15.8, 5.8, 17.8, 7.6)
            line(12.8, 9.8); p.closeSubpath()

        case .shell:
            move(12, 20); curve(3, 11, 6, 20, 3, 15)
            curve(21, 11, 3, 2, 21, 2)
            curve(12, 20, 21, 15, 18, 20)
            move(12, 20); line(12, 4)
            move(8, 19.2); line(6, 5.4); move(16, 19.2); line(18, 5.4)

        case .starfish:
            move(12, 3); line(14.6, 9.3); line(21.4, 9.8); line(16.2, 14.2)
            line(17.8, 20.8); line(12, 17.3); line(6.2, 20.8); line(7.8, 14.2)
            line(2.6, 9.8); line(9.4, 9.3); p.closeSubpath()

        case .driftwood:
            move(3, 14); curve(11, 12, 6, 11, 8, 15)
            curve(19, 11, 15, 14, 17, 10)
            move(4, 18); curve(12, 16, 7, 15, 9, 19)
            curve(20, 15, 16, 18, 18, 14)

        case .kelp:
            move(8, 21); curve(9, 10, 6.5, 17, 9, 14)
            curve(8, 3, 9.5, 7, 8, 6)
            move(14, 21); curve(14, 10, 16, 17, 14.5, 14)
            curve(15.5, 3, 13, 7, 15.5, 6)
            move(11, 21); curve(12, 13, 10.5, 18, 12, 16)

        case .bottle:
            move(10, 2); line(14, 2); line(14, 6.5)
            curve(15.2, 8.8, 14, 7.5, 14.6, 8.2)
            curve(16.5, 11.8, 16.1, 9.8, 16.5, 10.6)
            line(16.5, 19)
            curve(13.5, 22, 16.5, 20.7, 15.2, 22)
            line(10.5, 22); curve(7.5, 19, 8.8, 22, 7.5, 20.7)
            line(7.5, 11.8); curve(9, 8.8, 7.5, 10.6, 7.9, 9.8)
            curve(10, 6.5, 9.4, 8.2, 10, 7.5)
            p.closeSubpath()
            move(9.5, 13); line(14.5, 13)

        case .cairn:
            move(8, 20); line(16, 20)
            ellipse(12, 18, 5, 2.2)
            ellipse(12, 13.6, 3.8, 1.9)
            ellipse(12, 9.8, 2.7, 1.6)
            ellipse(12, 6.6, 1.7, 1.2)

        // MARK: Interface

        case .undo:
            move(4, 10); line(9, 10); move(4, 10); line(4, 5)
            move(4, 10); curve(20, 14, 9, 2, 20, 6)

        case .redo:
            move(20, 10); line(15, 10); move(20, 10); line(20, 5)
            move(20, 10); curve(4, 14, 15, 2, 4, 6)

        case .camera:
            move(3.5, 8); line(8, 8); line(9.5, 5.5); line(14.5, 5.5); line(16, 8)
            line(20.5, 8); line(20.5, 19); line(3.5, 19); p.closeSubpath()
            circle(12, 13, 4)

        case .tide:
            move(2, 9); curve(12, 9, 4.5, 6, 9.5, 12)
            curve(22, 9, 14.5, 6, 19.5, 12)
            move(2, 14); curve(12, 14, 4.5, 11, 9.5, 17)
            curve(22, 14, 14.5, 11, 19.5, 17)
            move(2, 19); curve(12, 19, 4.5, 16, 9.5, 22)
            curve(22, 19, 14.5, 16, 19.5, 22)

        case .sun:
            circle(12, 12, 4.6)
            for i in 0..<8 {
                let a = Double(i) / 8 * 2 * .pi
                let inner: CGFloat = 7.2, outer: CGFloat = 9.8
                move(12 + cos(a) * inner, 12 + sin(a) * inner)
                line(12 + cos(a) * outer, 12 + sin(a) * outer)
            }

        case .cloud:
            move(6.5, 18)
            curve(6.5, 10.5, 3.2, 18, 3.2, 11.5)
            curve(11, 6.5, 3.6, 8, 6.8, 6.5)
            curve(15.4, 10.2, 13.4, 6.5, 15.2, 8.2)
            curve(20.5, 14.2, 19, 10, 20.8, 11.4)
            curve(17.5, 18, 20.4, 16.6, 19.2, 18)
            p.closeSubpath()

        case .layers:
            move(12, 3); line(21, 8); line(12, 13); line(3, 8); p.closeSubpath()
            move(3, 12); line(12, 17); line(21, 12)
            move(3, 16); line(12, 21); line(21, 16)

        case .settings:
            circle(12, 12, 3.2)
            for i in 0..<6 {
                let a = Double(i) / 6 * 2 * .pi
                move(12 + cos(a) * 5.6, 12 + sin(a) * 5.6)
                line(12 + cos(a) * 9.2, 12 + sin(a) * 9.2)
            }

        case .close:
            move(6, 6); line(18, 18); move(18, 6); line(6, 18)

        case .play:
            move(7, 4.5); line(19, 12); line(7, 19.5); p.closeSubpath()

        case .pause:
            move(8.5, 5); line(8.5, 19); move(15.5, 5); line(15.5, 19)

        case .restart:
            move(12, 4.5)
            curve(12, 19.5, 20, 4.5, 20, 19.5)
            curve(4.5, 12, 4, 19.5, 4, 14)
            move(4.5, 12); line(8.4, 13.4); move(4.5, 12); line(3.4, 15.9)

        case .info:
            circle(12, 12, 9)
            move(12, 10.6); line(12, 16.6)
            circle(12, 7.6, 0.35)

        // Corner brackets, opening outward: give the beach the whole screen.
        case .expand:
            move(4, 9);   line(4, 4);   line(9, 4)
            move(15, 4);  line(20, 4);  line(20, 9)
            move(20, 15); line(20, 20); line(15, 20)
            move(9, 20);  line(4, 20);  line(4, 15)

        // The same brackets, closing inward: give the controls back.
        case .collapse:
            move(4, 9);   line(9, 9);   line(9, 4)
            move(15, 4);  line(15, 9);  line(20, 9)
            move(20, 15); line(15, 15); line(15, 20)
            move(9, 20);  line(9, 15);  line(4, 15)
        }

        return p
    }
}

/// A glyph at a given size, stroked in the current foreground colour. Rounded
/// joins throughout, which is what makes a line drawing read as drawn rather
/// than as plotted.
struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 24
    var weight: CGFloat = 1.6

    var body: some View {
        GlyphShape(glyph: glyph)
            .stroke(style: StrokeStyle(lineWidth: weight * (size / 24),
                                       lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - Content bindings

extension Tool {
    var glyph: Glyph {
        switch id {
        case .dig:   return .dig
        case .pour:  return .pour
        case .drip:  return .drip
        case .mould: return .mould
        case .wall:  return .wall
        case .pack:  return .pack
        case .wet:   return .wet
        case .carve: return .carve
        case .level: return .level
        case .place: return .place
        }
    }
}

extension Mould {
    var glyph: Glyph {
        switch id {
        case .turret:    return .mTurret
        case .keep:      return .mKeep
        case .gatehouse: return .mGate
        case .starFort:  return .mStar
        case .ziggurat:  return .mZiggurat
        case .spire:     return .mSpire
        case .scallop:   return .mScallop
        case .fish:      return .mFish
        case .crab:      return .mCrab
        case .starfish:  return .mStarfish
        }
    }
}

extension Adornment {
    var glyph: Glyph {
        switch id {
        case .pennant:      return .pennant
        case .parasol:      return .parasol
        case .pinwheel:     return .pinwheel
        case .lantern:      return .lantern
        case .pailAndSpade: return .pailSpade
        case .boat:         return .boat
        case .shell:        return .shell
        case .starfish:     return .starfish
        case .driftwood:    return .driftwood
        case .kelp:         return .kelp
        case .bottle:       return .bottle
        case .cairn:        return .cairn
        }
    }
}
