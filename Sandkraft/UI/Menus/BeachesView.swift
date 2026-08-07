//
//  BeachesView.swift
//  Sandkraft
//
//  The shelf: every beach you have kept, and the one in front of you waiting to
//  join them.
//
//  This exists because ⌘S used to open a file panel, and a file panel is the
//  wrong shape for a game. It is exactly right for a word processor — the
//  document is the point, and where it lives is the player's business. For a
//  sandcastle it is an interruption that asks a question nobody has an answer
//  to. "Which folder?" None. Just keep it.
//
//  So: type a name or do not, press the button, and it is on the shelf. The file
//  panel is still here, at the bottom, under **Export** — because handing a
//  castle to somebody else is a real thing to want and a file is how you do it.
//

import Foundation
import SwiftUI

struct BeachesView: View {
    @Bindable var model: GameModel

    /// Read once when the view appears and after every change, rather than
    /// recomputed in `body`. `body` runs whenever anything observable moves,
    /// and hitting the filesystem from it would mean listing a directory
    /// several times a second for a list that changes when the player says so.
    @State private var beaches: [SavedBeach] = []
    @State private var newName: String = ""
    @State private var renaming: SavedBeach?
    @State private var renameTo: String = ""
    @State private var confirmingDelete: SavedBeach?

    private var currentResolution: Int { model.qualityTier.simResolution }

    var body: some View {
        Form {
            keepSection
            shelfSection
            filesSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onAppear(perform: refresh)
        .alert("Rename beach", isPresented: renamingBinding) {
            TextField("Name", text: $renameTo)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this beach?",
                            isPresented: deletingBinding,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("The sand in it goes with it. This cannot be undone.")
        }
    }

    // MARK: - Sections

    private var keepSection: some View {
        Section("Keep this beach") {
            TextField(BeachLibrary.suggestedName(), text: $newName)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .autocorrectionDisabled()
                #endif

            Button("Keep it") {
                model.saveBeachToLibrary(named: newName)
                newName = ""
                // The write happens on the next frame, on the render thread, so
                // there is nothing to list yet. Refreshing when the model says
                // it has finished is what `beachMessage` below is for.
            }

            Text("""
                 Kept inside the game, not in a folder you have to find again. \
                 Leave the name empty and it takes today's date. Two beaches \
                 with the same name is fine — the second becomes “2”.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
        // The list is stale the moment a save lands, and a save lands a frame or
        // two after the button, from a Metal completion handler. This is the
        // signal that it did.
        .onChange(of: model.beachMessage) { _, _ in refresh() }
    }

    @ViewBuilder
    private var shelfSection: some View {
        Section("Kept beaches") {
            if beaches.isEmpty {
                Text("Nothing kept yet. The beach in front of you is one button away.")
                    .font(.skCaption)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(beaches) { beach in
                    BeachRow(beach: beach,
                             loadable: beach.loadable(into: currentResolution),
                             open: { open(beach) },
                             rename: { beginRename(beach) },
                             delete: { confirmingDelete = beach })
                }
            }
        }
    }

    private var filesSection: some View {
        Section("Files") {
            // Both ask for a system panel, and a panel cannot go up over a
            // sheet — which this view often is. Asking and then standing aside
            // lets `PlayView` queue the request and raise it once this has
            // finished leaving. See `PlayView.present(_:)`.
            Button("Export to a file…") {
                model.saveBeach()
                model.dismissSheetsWanted = true
            }
            Button("Import from a file…") {
                model.openBeach()
                model.dismissSheetsWanted = true
            }
            Text("""
                 For getting a beach off this machine, or onto it. Everything \
                 above stays in the game; this is the door to everywhere else.
                 """)
                .font(.skCaption)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    // MARK: - Actions

    private func refresh() {
        beaches = BeachLibrary.list()
    }

    private func open(_ beach: SavedBeach) {
        guard let data = BeachLibrary.read(beach) else {
            model.beachMessage = "That beach could not be read."
            return
        }
        model.pendingBeachLoad = data
        // Get out of the way of the thing that is about to appear. Loading a
        // beach and then being left staring at a list of beaches is the sort of
        // small rudeness that makes an interface feel unfinished.
        model.dismissSheetsWanted = true
    }

    private func beginRename(_ beach: SavedBeach) {
        renameTo = beach.name
        renaming = beach
    }

    private func commitRename() {
        guard let beach = renaming else { return }
        renaming = nil
        if !BeachLibrary.rename(beach, to: renameTo) {
            model.beachMessage = "There is already a beach called that."
        }
        refresh()
    }

    private func commitDelete() {
        guard let beach = confirmingDelete else { return }
        confirmingDelete = nil
        BeachLibrary.delete(beach)
        refresh()
    }

    // MARK: - Presentation bindings
    //
    // `alert` and `confirmationDialog` want a `Bool`; what the view actually has
    // is the beach being acted on. Deriving the flag from the optional keeps one
    // source of truth instead of a flag and a value that can disagree about
    // whether there is anything to rename.

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil },
                set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } })
    }
}

/// One beach on the shelf.
///
/// The whole row opens it, because that is what a row in a list of saves is for.
/// Rename and delete are secondary and sit behind a menu rather than in the row:
/// three tap targets in one row means two of them get hit by accident, and one
/// of those two deletes an afternoon.
struct BeachRow: View {
    let beach: SavedBeach
    let loadable: Bool
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: Metric.m) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(beach.name)
                        .font(Typeface.font(13, .medium))
                        .foregroundStyle(loadable ? Palette.primaryText
                                                  : Palette.secondaryText)
                    Text(caption)
                        .font(.skCaption)
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!loadable)

            Menu {
                Button("Open", action: open).disabled(!loadable)
                Button("Rename…", action: rename)
                Button("Delete", role: .destructive, action: delete)
            } label: {
                GlyphView(glyph: .settings, size: 15, weight: 1.6)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .fixedSize()
            .accessibilityLabel("Actions for \(beach.name)")
        }
    }

    /// Mode, when, and — only when it matters — why it will not open.
    ///
    /// The resolution is not interesting until it is the reason a beach is grey,
    /// so it is not mentioned until then. A row that always reported "448²"
    /// would be teaching every player a number they only need on the day
    /// something goes wrong.
    private var caption: String {
        let when = beach.header.savedAt.formatted(.relative(presentation: .named))
        if loadable {
            return "\(beach.header.mode.title) · \(when)"
        }
        return "\(beach.header.mode.title) · \(when) · saved at \(beach.header.simResolution)², change Quality to open"
    }
}
