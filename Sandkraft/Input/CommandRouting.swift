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

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .skSelectTool)) { note in
                guard let id = note.object as? ToolID,
                      model.availableTools.contains(where: { $0.id == id }) else { return }
                model.selectedToolID = id
            }
            .onReceive(NotificationCenter.default.publisher(for: .skAdjustBrush)) { note in
                guard let factor = note.object as? Double else { return }
                model.brushScale = min(max(model.brushScale * factor, 0.45), 2.0)
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .skShowFieldNotes)) { _ in
                sheet = .fieldNotes
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
                          sheet: Binding<PlaySheet?>) -> some View {
        modifier(CommandRouting(model: model, coordinator: coordinator, sheet: sheet))
    }
}
