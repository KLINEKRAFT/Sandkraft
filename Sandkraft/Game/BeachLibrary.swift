//
//  BeachLibrary.swift
//  Sandkraft
//
//  Beaches kept inside the game, under names you chose.
//
//  Until now there were exactly two ways a beach could be kept, and neither of
//  them was the obvious one. `BeachStore` holds a single autosave slot, silently,
//  which is a safety net rather than a save. And ⌘S opened a *file panel* —
//  which is correct behaviour for a document-based app and quite wrong for a
//  game. Nobody finishing a sandcastle wants to be asked which folder it goes
//  in. They want it to be there next time.
//
//  So: a folder the game owns, a list you can see, and a name you can type. The
//  file panel is still there under **Export**, because sending a castle to
//  somebody else is a real thing to want and a file is how you do it — but it is
//  no longer the only door, and it is no longer the one ⌘S opens.
//
//  Three decisions worth stating:
//
//  · **The filename is the name.** Not a UUID with the display name in a
//    sidecar, and not a name buried in the header. A folder of `.sandkraft`
//    files called things like `Big keep.sandkraft` is one somebody can open in
//    Finder, back up, rename, or hand to a friend without the game's help. The
//    format on disk stays exactly what `BeachDocumentFormat` writes, so a
//    library beach and an exported beach are the same bytes.
//
//  · **Application Support, not Documents.** On iOS, Documents is the folder the
//    Files app shows. These are the game's saves, not the player's paperwork,
//    and a folder that fills up with them uninvited is clutter.
//
//  · **Listing reads headers, not fields.** Ten saves at Maximum is 80 MB of
//    sand. The list needs a mode, a date and a resolution, all of which live in
//    the first few hundred bytes — so that is all it reads.
//

import Foundation

/// One beach on the shelf.
struct SavedBeach: Identifiable, Hashable, Sendable {
    /// The file itself, which is also the identity. Two beaches cannot share a
    /// name because two files cannot share a name.
    let url: URL
    let name: String
    let header: BeachHeader

    var id: URL { url }

    /// Beaches only load into a session running at the resolution they were
    /// written at — the field is a different size at every quality tier, and
    /// resampling somebody's castle is not a thing to do quietly.
    func loadable(into resolution: Int) -> Bool {
        header.simResolution == resolution
    }

    static func == (a: SavedBeach, b: SavedBeach) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

enum BeachLibrary {

    static let fileExtension = "sandkraft"

    /// How much of a file to read to find its header. Same reasoning as
    /// `BeachStore`: the header is a few hundred bytes of JSON and the field
    /// behind it is megabytes.
    private static let headerProbeBytes = 64 * 1024

    private static var folder: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true) else { return nil }
        let dir = base
            .appendingPathComponent("Sandkraft", isDirectory: true)
            .appendingPathComponent("Beaches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Reading

    /// Everything on the shelf, newest first.
    ///
    /// A file that will not parse is skipped rather than reported. The folder is
    /// somewhere a person can reach, so it can contain anything at all, and a
    /// library that refuses to open because somebody dropped a photograph in it
    /// would be a worse failure than a library that quietly lists eight of nine.
    static func list() -> [SavedBeach] {
        guard let folder,
              let names = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { return [] }

        return names
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url -> SavedBeach? in
                guard let header = header(at: url) else { return nil }
                return SavedBeach(url: url,
                                  name: url.deletingPathExtension().lastPathComponent,
                                  header: header)
            }
            .sorted { $0.header.savedAt > $1.header.savedAt }
    }

    private static func header(at url: URL) -> BeachHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let probe = try? handle.read(upToCount: headerProbeBytes), !probe.isEmpty else {
            return nil
        }
        return (try? BeachDocumentFormat.decodeHeader(probe))?.header
    }

    static func read(_ beach: SavedBeach) -> Data? {
        try? Data(contentsOf: beach.url, options: [.mappedIfSafe])
    }

    // MARK: - Writing

    /// Write a document under `name`. Returns the name it actually used.
    ///
    /// With `overwrite` false — the default, and what "keep a copy" means — a
    /// name already on the shelf counts up rather than replacing anything, so
    /// nothing is ever lost to a reflex.
    ///
    /// With `overwrite` true, the named beach is replaced in place. That is only
    /// ever reached from ⌘S on a beach this session already owns, or from **Save
    /// over this** on a row somebody deliberately pointed at.
    ///
    /// Called off the main actor, from the command buffer's completion handler.
    @discardableResult
    static func write(_ data: Data, name: String, overwrite: Bool = false) -> String? {
        guard let folder else { return nil }
        let resolved = overwrite ? sanitised(name) : uniqueName(from: name)
        guard !resolved.isEmpty else { return nil }
        let url = folder.appendingPathComponent(resolved).appendingPathExtension(fileExtension)
        do {
            // Atomic either way. Replacing a save is the one moment the old one
            // is most worth not losing: a non-atomic overwrite that dies halfway
            // leaves neither the new beach nor the old one.
            try data.write(to: url, options: [.atomic])
            return resolved
        } catch {
            return nil
        }
    }

    static func delete(_ beach: SavedBeach) {
        try? FileManager.default.removeItem(at: beach.url)
    }

    /// Rename in place. Returns false when the new name is taken or unusable,
    /// so the interface can say so rather than appearing to succeed.
    static func rename(_ beach: SavedBeach, to newName: String) -> Bool {
        guard let folder else { return false }
        let cleaned = sanitised(newName)
        guard !cleaned.isEmpty else { return false }
        if cleaned == beach.name { return true }

        let destination = folder.appendingPathComponent(cleaned)
            .appendingPathExtension(fileExtension)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        return (try? FileManager.default.moveItem(at: beach.url, to: destination)) != nil
    }

    // MARK: - Names

    /// A filename that cannot break a path or a listing.
    ///
    /// `/` is the path separator on both platforms and `:` is what the Finder
    /// still shows a `/` as, so both have to go. Leading dots are stripped
    /// because a file called `.keep` is an invisible one, and a save the player
    /// cannot see is a save they will think failed.
    static func sanitised(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: ":", with: "-")
        while s.hasPrefix(".") { s.removeFirst() }
        // Long enough for any name worth typing, short enough for every
        // filesystem this will ever land on.
        return String(s.prefix(64)).trimmingCharacters(in: .whitespaces)
    }

    /// `Big keep`, then `Big keep 2`, then `Big keep 3`.
    ///
    /// Counting up rather than overwriting, because ⌘S is a reflex and the cost
    /// of guessing wrong in the other direction is somebody's afternoon.
    static func uniqueName(from raw: String) -> String {
        guard let folder else { return sanitised(raw) }
        let base = sanitised(raw).isEmpty ? suggestedName() : sanitised(raw)

        var candidate = base
        var n = 2
        while FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(candidate)
                .appendingPathExtension(fileExtension).path) {
            candidate = "\(base) \(n)"
            n += 1
            // The loop is bounded because a filesystem is not: a folder that
            // somehow contains a thousand `Big keep`s should give up rather than
            // spin.
            if n > 1000 { return "\(base) \(UUID().uuidString.prefix(8))" }
        }
        return candidate
    }

    /// What ⌘S calls a beach when nobody has typed anything. The date, because a
    /// name the game invented should look like a timestamp rather than pretend
    /// to be a title.
    static func suggestedName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Beach \(formatter.string(from: date))"
    }
}
