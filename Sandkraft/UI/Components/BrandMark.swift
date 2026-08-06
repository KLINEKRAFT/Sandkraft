//
//  BrandMark.swift
//  Sandkraft
//
//  The Klinekraft mark on the title screen.
//
//  It loads from the asset catalogue when a file is present and falls back to a
//  typeset wordmark when one is not. That is not defensive coding for its own
//  sake: a logo that is still being worked on should not be able to leave a
//  blank rectangle in a shipping build, and the fallback is designed to look
//  like a choice rather than like a missing asset.
//
//  The imageset carries Any and Dark appearance slots. The title screen is
//  near-black, and a dark green mark on near-black is invisible — so the dark
//  slot wants the light version of the logo. The game forces dark mode, so that
//  is the one it will use.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct BrandMark: View {
    /// Height of the mark in points. Everything scales off this.
    var height: CGFloat = 26
    var tint: Color = Palette.secondaryText
    /// Shown above the mark. Nil hides it.
    var caption: String? = "Made by"

    /// Asset catalogue name. Drop `klinekraft-logo.pdf` (or a PNG set) in here
    /// and it appears; until then the fallback below stands in.
    static let assetName = "KlinekraftLogo"

    private var artworkExists: Bool {
        #if os(macOS)
        return NSImage(named: Self.assetName) != nil
        #else
        return UIImage(named: Self.assetName) != nil
        #endif
    }

    var body: some View {
        VStack(spacing: Metric.s) {
            if let caption {
                Text(caption).skLabelStyle(tint.opacity(0.7))
            }

            if artworkExists {
                Image(Self.assetName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(height: height)
                    .foregroundStyle(tint)
            } else {
                fallback
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Made by Klinekraft Design Co")
    }

    /// Typeset stand-in, shaped like the real mark: wordmark over a letterspaced
    /// rule line.
    private var fallback: some View {
        VStack(spacing: 3) {
            Text("KLINEKRAFT")
                .font(.skDisplay(height * 0.62, weight: .regular))
                .tracking(height * 0.13)
            Text("DESIGN CO")
                .font(.skDisplay(height * 0.26, weight: .bold))
                .tracking(height * 0.20)
        }
        .foregroundStyle(tint)
    }
}
