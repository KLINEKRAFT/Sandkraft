//
//  Theme.swift
//  Sandkraft
//
//  The whole visual language of the interface, in one file.
//
//  The brief for this rewrite was "clean and simplistic", and the temptation
//  with that brief is to make everything grey and call it restraint. What the
//  interface actually does is get out of the way of a full-bleed 3D scene: there
//  is no chrome, no window frame, no panel that is on screen when it is not
//  needed. What remains is typography, one accent, and materials that let the
//  beach through.
//
//  Three rules hold it together:
//
//    1. Nothing sits on an opaque background. Every surface is a material over
//       the scene, so the light on the beach reaches the interface.
//    2. Two type families and no more — SF for anything you read at a glance, New
//       York for anything you read as prose. The game has prose; it should look
//       like prose.
//    3. One spacing scale, one radius scale, one motion vocabulary. A control
//       that needs a bespoke number is a control that is in the wrong place.
//

import SwiftUI

// MARK: - Metrics

enum Metric {
    /// A four-point scale. Everything in the interface is a multiple of these,
    /// and there are no other numbers.
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48

    /// Corner radii. Continuous curvature throughout — the concentricity rules
    /// only work if the whole hierarchy uses the same curve family.
    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 16
    static let radiusLarge: CGFloat = 26
    static let radiusPanel: CGFloat = 30

    /// The minimum comfortable hit target. Anything smaller gets padding rather
    /// than an apology.
    static let touchTarget: CGFloat = 44

    static let railHeight: CGFloat = 78
    static let sidebarWidth: CGFloat = 96
    static let inspectorWidth: CGFloat = 300
}

// MARK: - Palette

enum Palette {
    /// The one accent. Wet sand catching the light — warm, and it never competes
    /// with the sea.
    static let accent = Color(red: 0.94, green: 0.66, blue: 0.31)
    static let accentDeep = Color(red: 0.78, green: 0.46, blue: 0.17)

    /// Used only for the tide: the water rising is the only thing in this game
    /// that is genuinely urgent, so it is the only thing allowed to be blue.
    static let tide = Color(red: 0.36, green: 0.70, blue: 0.80)
    static let tideDeep = Color(red: 0.16, green: 0.42, blue: 0.55)

    static let good = Color(red: 0.44, green: 0.78, blue: 0.55)
    static let warning = Color(red: 0.94, green: 0.72, blue: 0.32)
    static let danger = Color(red: 0.92, green: 0.44, blue: 0.36)

    /// Moisture, as a continuous ramp from bone dry to soup. This is the single
    /// most information-dense colour in the game and it is worth being exact
    /// about: the middle of the ramp — where sand builds best — is the only part
    /// that is warm.
    static func moisture(_ m: Double) -> Color {
        switch m {
        case ..<0.12: return Color(red: 0.86, green: 0.80, blue: 0.68)   // bone dry
        case ..<0.35: return Color(red: 0.90, green: 0.74, blue: 0.45)   // damp
        case ..<0.72: return accent                                       // builds best
        case ..<0.90: return Color(red: 0.52, green: 0.72, blue: 0.78)   // wet
        default:      return Color(red: 0.38, green: 0.55, blue: 0.72)   // running
        }
    }

    static func moistureLabel(_ m: Double) -> String {
        switch m {
        case ..<0.12: return "Bone dry"
        case ..<0.35: return "Dry"
        case ..<0.55: return "Damp"
        case ..<0.72: return "Good"
        case ..<0.90: return "Wet"
        default:      return "Saturated"
        }
    }

    /// Text on materials. Deliberately the system semantic colours rather than
    /// fixed greys, so Increase Contrast and dark mode both work for free.
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let hairline = Color.primary.opacity(0.10)
}

// MARK: - Typography

extension Font {
    /// Prose. The tide names, the epigraphs, the field notes. A game that writes
    /// in sentences should set them like sentences.
    static func skSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Numbers that change every frame. Monospaced digits, or the clock jitters
    /// and the eye follows the jitter instead of the number.
    static func skNumeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static let skTitle = Font.skSerif(34, weight: .semibold)
    static let skHeadline = Font.skSerif(22, weight: .semibold)
    static let skBody = Font.system(.body)
    static let skCaption = Font.system(.caption)
    static let skLabel = Font.system(size: 11, weight: .semibold).width(.expanded)
}

// MARK: - Motion
//
// One spring for interface, one for anything the player is directly dragging,
// and one slow one for scene-scale transitions. Three, and no ad-hoc animations
// anywhere else in the project.

extension Animation {
    /// Buttons, panels, selection.
    static let skSnap = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Anything under a finger. Faster, so it tracks.
    static let skTrack = Animation.spring(response: 0.18, dampingFraction: 0.90)
    /// Screen changes, tide transitions, the results card.
    static let skSlow = Animation.spring(response: 0.62, dampingFraction: 0.88)
}

// MARK: - Surfaces

/// The one panel style. Everything floating over the scene is one of these.
struct PanelBackground: ViewModifier {
    var radius: CGFloat = Metric.radiusPanel
    var material: Material = .regularMaterial
    var stroke: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(material)
            }
            .overlay {
                if stroke {
                    // A single hairline, not a border. It exists to separate the
                    // panel from a bright sky, and it is invisible against a dark
                    // one — which is correct.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
    }
}

extension View {
    func skPanel(radius: CGFloat = Metric.radiusPanel,
                 material: Material = .regularMaterial,
                 stroke: Bool = true) -> some View {
        modifier(PanelBackground(radius: radius, material: material, stroke: stroke))
    }

    /// Content that must stay legible over a scene that can be any colour at all
    /// — a white beach at noon or a black one at midnight.
    func skLegible() -> some View {
        shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }
}

// MARK: - Press feedback

/// A button style that feels like pressing something physical. Scale and a
/// slight dim, with the spring tuned so the release overshoots by a hair.
struct SoftButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.skTrack, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { SoftButtonStyle() }
}
