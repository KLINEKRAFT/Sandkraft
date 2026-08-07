//
//  BeachStore.swift
//  Sandkraft
//
//  The beach you were working on, kept between launches.
//
//  Until now nothing about a session survived quitting. `Preferences` kept the
//  settings and the campaign progress, and "Save This Beach…" wrote a file if
//  you thought to ask for one — but close the app with an hour of work on the
//  screen and the work was gone, silently, with nothing having warned you that
//  it would be. That is not a missing feature so much as a promise the rest of
//  the app was already making: the title screen has said *Resume* since the
//  first build, and it meant "resume until you quit".
//
//  So there is one autosave slot, written on a timer while you play and read
//  once at launch. It is deliberately not a save *system*:
//
//    · One slot. Named saves are what "Save This Beach…" is for, and they go
//      wherever the player puts them. This one lives somewhere they will never
//      have to look.
//    · Written from the same document format as an exported beach, which means
//      it is the same code path, the same magic number and the same bounds
//      checks. A private format for this would be a second parser to get wrong.
//    · Application Support, not Documents. On iOS, Documents is the folder the
//      Files app shows, and an autosave appearing there next to the beaches
//      somebody deliberately saved is clutter they did not ask for.
//    · Nothing here throws upward. A failed autosave is not a thing to interrupt
//      anyone about, and a corrupt one is a thing to ignore rather than a thing
//      to refuse to launch over.
//

import Foundation

enum BeachStore {

    /// How much of the file to read when all that is wanted is the header. The
    /// header is a few hundred bytes of JSON; the field behind it is megabytes,
    /// and the title screen only needs to know whether the sand is loadable —
    /// not what it looks like.
    private static let headerProbeBytes = 64 * 1024

    private static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let folder = base.appendingPathComponent("Sandkraft", isDirectory: true)
        // `create: true` above makes Application Support itself, not our folder
        // in it. On a fresh install neither exists.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var fileURL: URL? {
        directory?.appendingPathComponent("autosave.sandkraft", isDirectory: false)
    }

    /// Write the slot. Atomic, because the alternative is a half-written beach
    /// on the one occasion it matters — the app being killed mid-write is
    /// exactly the case this whole file exists to survive.
    ///
    /// Called off the main actor, from the command buffer's completion handler.
    static func write(_ data: Data) {
        guard let fileURL else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Deliberately silent. There is no version of "your automatic save
            // failed" that a player can act on mid-stroke, and the next one is
            // thirty seconds away.
        }
    }

    /// The whole slot, for handing to the simulation.
    static func read() -> Data? {
        guard let fileURL else { return nil }
        return try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    /// Just the header, without reading the field.
    ///
    /// Returns nil for every kind of "no" there is — no file, a truncated one,
    /// one written by a newer version, or one somebody replaced with a
    /// photograph of a cat. The caller's only question is whether to offer to
    /// continue, and the answer to all of those is the same.
    static func storedHeader() -> BeachHeader? {
        guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let probe = try? handle.read(upToCount: headerProbeBytes), !probe.isEmpty else {
            return nil
        }
        return (try? BeachDocumentFormat.decodeHeader(probe))?.header
    }

    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
