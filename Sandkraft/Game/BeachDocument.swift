//
//  BeachDocument.swift
//  Sandkraft
//
//  A castle, on disk.
//
//  Format: a small container rather than one JSON blob, because the bulk of a
//  save is the simulation field — up to 640² RGBA32Float, which is 6.5 MB of
//  raw floats. Base64 inside JSON would inflate that by a third and cost a
//  parse of several million characters to get it back. So the metadata is JSON
//  and the field is appended raw.
//
//      "SKFT"            4 bytes, magic
//      UInt32            format version, little endian
//      UInt32            header length in bytes, little endian
//      <header>          UTF-8 JSON
//      <field>           resolution² × 16 bytes, straight from the texture
//
//  The magic is checked rather than trusted to the file extension: a document
//  type is a hint, and the first thing anyone does with a new format is rename
//  something to see what happens.
//

import Foundation

// MARK: - Header

/// Everything about a saved beach except the sand itself.
struct BeachHeader: Codable, Sendable {
    /// The resolution the field was written at. A save made on Detail cannot be
    /// loaded into Battery — the arrays are different sizes — and this is what
    /// lets the interface say so in a sentence instead of failing obscurely.
    var simResolution: Int

    var mode: GameMode
    var tideNumber: Int
    var lookID: LookID
    var dayFraction: Double
    var cloudCover: Double
    var props: [PlacedProp]
    var savedAt: Date
}

// MARK: - Container

enum BeachDocumentFormat {
    static let magic: [UInt8] = Array("SKFT".utf8)
    static let version: UInt32 = 1

    enum Failure: LocalizedError {
        case notASandkraftFile
        case fromANewerVersion(UInt32)
        case damaged
        case wrongResolution(saved: Int, current: Int)

        var errorDescription: String? {
            switch self {
            case .notASandkraftFile:
                return "That is not a Sandkraft beach."
            case .fromANewerVersion(let v):
                return "That beach was saved by a newer version of Sandkraft (format \(v))."
            case .damaged:
                return "That beach file is damaged and could not be read."
            case .wrongResolution(let saved, let current):
                return """
                       That beach was saved at \(saved)² and this session is \
                       running at \(current)². Change Quality to match and open \
                       it again.
                       """
            }
        }
    }

    static func encode(header: BeachHeader, field: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let headerData = try encoder.encode(header)

        var out = Data()
        out.append(contentsOf: magic)
        withUnsafeBytes(of: version.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(headerData.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(headerData)
        out.append(field)
        return out
    }

    /// The header alone, and how many bytes of the file it accounted for.
    ///
    /// Split out from `decode` so that a caller holding only the first few
    /// kilobytes of a file — the autosave slot being probed at launch, where
    /// reading several megabytes of sand to find out whether it is loadable at
    /// all would be silly — runs exactly the same parser as a caller holding the
    /// whole of one. Two parsers for one format is how the second one ends up
    /// trusting a length the first one checks.
    static func decodeHeader(_ data: Data) throws -> (header: BeachHeader, fieldStart: Int) {
        // Every read below is bounds-checked before it happens. This parses a
        // file the user chose from disk, which is to say a file that can contain
        // anything at all, including a length field that claims four gigabytes.
        guard data.count >= 12 else { throw Failure.notASandkraftFile }
        guard Array(data.prefix(4)) == magic else { throw Failure.notASandkraftFile }

        let version = readUInt32(data, at: 4)
        guard version <= Self.version else { throw Failure.fromANewerVersion(version) }

        let headerLength = Int(readUInt32(data, at: 8))
        let headerStart = 12
        let headerEnd = headerStart + headerLength
        guard headerLength > 0, headerEnd <= data.count else { throw Failure.damaged }

        // Indices relative to `startIndex`, not to zero. A `Data` that arrived
        // as a slice of another one does not start at zero, and subscripting it
        // as though it did traps rather than misreads.
        let base = data.startIndex
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(
            BeachHeader.self,
            from: data.subdata(in: (base + headerStart)..<(base + headerEnd))
        ) else {
            throw Failure.damaged
        }
        guard header.simResolution > 0 else { throw Failure.damaged }

        return (header, headerEnd)
    }

    static func decode(_ data: Data) throws -> (header: BeachHeader, field: Data) {
        let (header, fieldStart) = try decodeHeader(data)

        let base = data.startIndex
        let field = data.subdata(in: (base + fieldStart)..<data.endIndex)
        let expected = header.simResolution * header.simResolution * 16
        guard field.count == expected else { throw Failure.damaged }

        return (header, field)
    }

    /// Little-endian, byte by byte. `load(as:)` on a `Data` slice is not
    /// guaranteed to be aligned, and an unaligned load is undefined rather than
    /// merely slow.
    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }

    /// A filename with the moment in it, matching the photographs.
    static func suggestedFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Beach \(formatter.string(from: date))"
    }
}
