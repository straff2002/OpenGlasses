import Foundation

/// Versioned envelope for moving a skills library between devices as a single JSON file. The
/// `schemaVersion` lets the on-disk format evolve without breaking older exports — the same
/// discipline a vault manifest applies with its `version` field.
///
/// Used for both the ClawHub installed-skills library (`InstalledSkillStore`) and the voice-taught
/// skills library (`VoiceSkillStore`).
struct SkillsLibraryEnvelope<Item: Codable>: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let items: [Item]

    init(items: [Item], schemaVersion: Int = SkillsLibraryIO.schemaVersion, exportedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.items = items
    }
}

enum SkillsLibraryIO {
    static let schemaVersion = 1

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Write `data` to a uniquely-named temp file and return its URL for sharing via `ShareSheet`.
    static func writeTempFile(_ data: Data, named filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillsExport-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
