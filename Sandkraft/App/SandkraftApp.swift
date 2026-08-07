//
//  SandkraftApp.swift
//  Sandkraft
//
//  One multiplatform target. The iPhone build and the Mac build are the same
//  binary target compiled twice, not a shared framework with two shells: about
//  ninety per cent of the code is genuinely identical, and the ten per cent that
//  is not is input handling and window chrome, which is exactly the ten per cent
//  that should differ.
//

import SwiftUI

@main
struct SandkraftApp: App {

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { SandkraftCommands() }
        #endif
    }
}

#if os(macOS)

/// The menu bar. A Mac app without one is a phone app in a window, and every
/// item here is something a keyboard-first player will reach for.
struct SandkraftCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open a Beach…") {
                NotificationCenter.default.post(name: .skOpenBeach, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save This Beach…") {
                NotificationCenter.default.post(name: .skSaveBeach, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command])
        }

        // Undo and redo were routed but never bound. `CommandRouting` has
        // listened for both notifications since the first build and nothing has
        // ever posted them, so ⌘Z — the one shortcut every Mac user tries
        // without thinking — did nothing at all.
        //
        // These stay enabled even with an empty stack rather than reaching for
        // `model.canUndo`: a `Commands` body is built at app scope, where no
        // model exists yet, and `SceneCoordinator.undo()` is already a no-op
        // when there is nothing to undo. A menu item that is always live and
        // sometimes silent is a far smaller lie than a shortcut that is absent.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                NotificationCenter.default.post(name: .skUndo, object: nil)
            }
            .keyboardShortcut("z", modifiers: [.command])

            Button("Redo") {
                NotificationCenter.default.post(name: .skRedo, object: nil)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        // Settings lives in the app menu at ⌘, on every Mac ever made. Leaving it
        // behind an unlabelled gear in a floating overlay was a straight miss.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .skShowSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("Tools") {
            ForEach(Tool.all) { tool in
                Button(tool.name) {
                    NotificationCenter.default.post(name: .skSelectTool, object: tool.id)
                }
                .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [])
            }
            Divider()
            // Detents, not factors. The size control is logarithmic, so one
            // press is one step of the same size wherever you are in the range
            // — and the menu no longer has to know what that size is.
            Button("Bigger brush") {
                NotificationCenter.default.post(name: .skAdjustBrush, object: 1.0)
            }
            .keyboardShortcut("]", modifiers: [])
            Button("Smaller brush") {
                NotificationCenter.default.post(name: .skAdjustBrush, object: -1.0)
            }
            .keyboardShortcut("[", modifiers: [])

            Divider()
            Button("Round brush") {
                NotificationCenter.default.post(name: .skSetBrushShape,
                                                object: BrushShape.round.rawValue)
            }
            .keyboardShortcut("b", modifiers: [.command])
            Button("Square brush") {
                NotificationCenter.default.post(name: .skSetBrushShape,
                                                object: BrushShape.square.rawValue)
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }

        CommandMenu("Beach") {
            Button("Take a photograph…") {
                NotificationCenter.default.post(name: .skTakePhoto, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Pause") {
                NotificationCenter.default.post(name: .skTogglePause, object: nil)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("Reset the beach") {
                NotificationCenter.default.post(name: .skResetBeach, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            // Not "Enter Full Screen" — the window is already whatever size it
            // is. This puts the interface away and leaves the beach.
            Button("Hide the controls") {
                NotificationCenter.default.post(name: .skToggleChrome, object: nil)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Next look") {
                NotificationCenter.default.post(name: .skCycleLook, object: 1)
            }
            .keyboardShortcut("l", modifiers: [.command])
            Button("Previous look") {
                NotificationCenter.default.post(name: .skCycleLook, object: -1)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Field Notes") {
                NotificationCenter.default.post(name: .skShowFieldNotes, object: nil)
            }
            .keyboardShortcut("/", modifiers: [.command])
        }
    }
}

#endif

// MARK: - Command routing
//
// NotificationCenter rather than a shared observable object, because menu
// commands are built once at app scope and would otherwise have to reach into a
// model that does not exist yet at that point in the scene graph.

extension Notification.Name {
    static let skSelectTool = Notification.Name("sk.selectTool")
    static let skAdjustBrush = Notification.Name("sk.adjustBrush")
    static let skSetBrushShape = Notification.Name("sk.setBrushShape")
    static let skTakePhoto = Notification.Name("sk.takePhoto")
    static let skSaveBeach = Notification.Name("sk.saveBeach")
    static let skOpenBeach = Notification.Name("sk.openBeach")
    static let skTogglePause = Notification.Name("sk.togglePause")
    static let skToggleChrome = Notification.Name("sk.toggleChrome")
    static let skResetBeach = Notification.Name("sk.resetBeach")
    static let skCycleLook = Notification.Name("sk.cycleLook")
    static let skShowFieldNotes = Notification.Name("sk.showFieldNotes")
    static let skShowSettings = Notification.Name("sk.showSettings")
    static let skUndo = Notification.Name("sk.undo")
    static let skRedo = Notification.Name("sk.redo")
}
