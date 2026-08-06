//
//  Haptics.swift
//  Sandkraft
//
//  Deliberately small. UIFeedbackGenerator rather than Core Haptics, because
//  what this game needs is a handful of well-timed taps, not a custom haptic
//  score — and the generators are the ones the rest of the system uses, so they
//  feel like the phone rather than like an app doing an impression of one.
//
//  Everything is a no-op on the Mac, where there is nothing to vibrate.
//

import Foundation

#if os(iOS)
import UIKit
#endif

@MainActor
final class Haptics {

    enum Impact {
        case light, medium, heavy
    }

    var enabled = true

    #if os(iOS)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    /// The generators warm the Taptic Engine when prepared, which is the
    /// difference between a tap that lands with the touch and one that lands 40 ms
    /// after it. Re-preparing on every use keeps it warm through a stroke.
    init() {
        light.prepare()
        medium.prepare()
        selectionGenerator.prepare()
    }
    #else
    init() {}
    #endif

    func impact(_ kind: Impact) {
        guard enabled else { return }
        #if os(iOS)
        switch kind {
        case .light:  light.impactOccurred(intensity: 0.55); light.prepare()
        case .medium: medium.impactOccurred(intensity: 0.75); medium.prepare()
        case .heavy:  heavy.impactOccurred(intensity: 1.0); heavy.prepare()
        }
        #endif
    }

    /// A continuous stroke gets a very light tick at a fixed rate rather than one
    /// per frame — per frame is a buzz, and a buzz is the fastest way to make
    /// somebody turn haptics off for good.
    func strokeTick(intensity: Double) {
        guard enabled else { return }
        #if os(iOS)
        light.impactOccurred(intensity: max(min(intensity, 1), 0.15))
        light.prepare()
        #endif
    }

    func selection() {
        guard enabled else { return }
        #if os(iOS)
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
        #endif
    }

    func success() {
        guard enabled else { return }
        #if os(iOS)
        notification.notificationOccurred(.success)
        #endif
    }

    func warning() {
        guard enabled else { return }
        #if os(iOS)
        notification.notificationOccurred(.warning)
        #endif
    }
}
