//
//  CommandRouting.swift
//  Sandkraft
//
//  Turns menu-bar and keyboard commands into model changes.
//
//  Kept in one modifier rather than sprinkled through PlayView so that the
//  complete list of things a keyboard can do is in one place, and so the play
//  screen does not grow eight more `.onReceive` lines every time a shortcut is
//  added.
//
//  **Applied in groups, not as one chain**, for the same reason `PlayView.body`
//  and `SettingsView.body` are. Swift type-checks a whole expression at once
//  against a wall-clock budget, and a chain of twenty `.onReceive` calls — each
//  one a generic function taking the opaque result of the last — is a single
//  inference problem with twenty nested unknowns in it. This file went over the
//  budget the moment a twenty-first was added, and it did so on CI rather than
//  on a laptop, which is the only reason it was caught before shipping.
//
//  The rule this project now works to: **any view with more than about a dozen
//  chained modifiers gets split.** The grouping below is by what the commands
//  do, which makes the split useful to read as well as necessary to compile.
//

import SwiftUI

struct CommandRouting: ViewModifier {
    @Bindable var model: GameModel
    let coordinator: SceneCoordinator
    @Binding var sheet: PlaySheet?
    /// Interface state rather than model state — nothing outside the play screen
    /// has any business knowing whether its own panels are on screen — so it
    /// arrives here as a binding, the same way the sheet does.
    @Binding var chromeHidden: Bool

    func body(content: Content) -> some View {
        let withTools = toolCommands(content)
        let withBeaches = beachCommands(withTools)
        let withScene = sceneCommands(withBeaches)
        return panelCommands(withScene)
    }

    /// What is in your hand, and how it behaves.
    private func toolCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .skSelectTool)) { note in
                guard let id = note.object as? ToolID,
                      model.availableTools.contains(where: { $0.id == id }) else { return }
                model.selectedToolID = id
            }
            .onReceive(NotificationCenter.default.publisher(for: .skAdjustBrush)) { note in
                guard let steps = note.object as? Double else { return }
                model.nudgeBrushSize(by: steps)
            }
            .onReceive(NotificationCenter.default.publisher(for: .skSetBrushShape)) { note in
                guard let raw = note.object as? String,
                      let shape = BrushShape(rawValue: raw) else { return }
                model.brushShape = shape
            }
            .onReceive(NotificationCenter.default.publisher(for: .skToggleSnapToGrid)) { _ in
                model.snapToGrid.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skToggleStraightStrokes)) { _ in
                model.straightStrokes.toggle()
            }
    }

    /// Keeping a beach, letting one go, and getting one in or out of a file.
    private func beachCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .skKeepBeach)) { _ in
                // No name and no dialog. ⌘S is a reflex, and a reflex that stops
                // to ask a question is one people stop using. After the first
                // one it saves over the same beach rather than breeding
                // timestamps.
                model.quickSaveBeach()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skShowBeaches)) { _ in
                sheet = .beaches
            }
            .onReceive(NotificationCenter.default.publisher(for: .skSaveBeach)) { _ in
                model.saveBeach()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skOpenBeach)) { _ in
                model.openBeach()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skTakePhoto)) { _ in
                model.takePhoto()
            }
    }

    /// The beach itself: time, history, and what it looks like.
    private func sceneCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .skTogglePause)) { _ in
                model.isPaused.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skResetBeach)) { _ in
                coordinator.resetBeach()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skCycleLook)) { note in
                let step = (note.object as? Int) ?? 1
                let all = LookID.allCases
                guard let index = all.firstIndex(of: model.lookID) else { return }
                let next = (index + step + all.count) % all.count
                model.lookID = all[next]
            }
            .onReceive(NotificationCenter.default.publisher(for: .skUndo)) { _ in
                coordinator.undo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skRedo)) { _ in
                coordinator.redo()
            }
    }

    /// What is on screen over the top of it.
    private func panelCommands<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .skToggleChrome)) { _ in
                chromeHidden.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skCentreView)) { _ in
                coordinator.centreView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skShowFieldNotes)) { _ in
                sheet = .fieldNotes
            }
            .onReceive(NotificationCenter.default.publisher(for: .skShowSettings)) { _ in
                sheet = .settings
            }
    }
}

extension View {
    func skCommandRouting(model: GameModel,
                          coordinator: SceneCoordinator,
                          sheet: Binding<PlaySheet?>,
                          chromeHidden: Binding<Bool>) -> some View {
        modifier(CommandRouting(model: model, coordinator: coordinator,
                                sheet: sheet, chromeHidden: chromeHidden))
    }
}
