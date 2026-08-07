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
        content
            .onReceive(NotificationCenter.default.publisher(for: .skToggleChrome)) { _ in
                chromeHidden.toggle()
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .skTakePhoto)) { _ in
                model.takePhoto()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skSaveBeach)) { _ in
                model.saveBeach()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skOpenBeach)) { _ in
                model.openBeach()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skTogglePause)) { _ in
                model.isPaused.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skToggleSnapToGrid)) { _ in
                model.snapToGrid.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skToggleStraightStrokes)) { _ in
                model.straightStrokes.toggle()
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
            .onReceive(NotificationCenter.default.publisher(for: .skShowFieldNotes)) { _ in
                sheet = .fieldNotes
            }
            .onReceive(NotificationCenter.default.publisher(for: .skShowSettings)) { _ in
                sheet = .settings
            }
            .onReceive(NotificationCenter.default.publisher(for: .skUndo)) { _ in
                coordinator.undo()
            }
            .onReceive(NotificationCenter.default.publisher(for: .skRedo)) { _ in
                coordinator.redo()
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
