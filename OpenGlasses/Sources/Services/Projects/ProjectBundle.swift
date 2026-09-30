import Foundation

/// A portable snapshot of a Project (Plan AN) — a `Persona` plus its scoped documents'
/// text — for export/import between devices. Pure `Codable`; the live read/write of the
/// `DocumentStore` + persona list lives in `ProjectExporter`.
struct ProjectBundle: Codable, Equatable {
    /// Bumped if the on-disk shape changes; decode rejects unknown future versions.
    static let currentVersion = 1

    var version: Int
    var persona: Persona
    var documents: [BundledDocument]

    init(persona: Persona, documents: [BundledDocument], version: Int = ProjectBundle.currentVersion) {
        self.version = version
        self.persona = persona
        self.documents = documents
    }

    /// One document carried by value (name + type + full reconstructed text), so the
    /// importer can re-ingest it into the new device's store.
    struct BundledDocument: Codable, Equatable {
        let name: String
        let sourceType: String
        let text: String
    }
}

/// Pure JSON encode/decode for a `ProjectBundle` (Plan AN). Headless-testable round-trip;
/// rejects a bundle from a newer schema version rather than silently mis-importing.
enum ProjectBundleCodec {
    enum CodecError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This project bundle (v\(v)) was made by a newer version of Avenkin."
            }
        }
    }

    static func encode(_ bundle: ProjectBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    static func decode(_ data: Data) throws -> ProjectBundle {
        let bundle = try JSONDecoder().decode(ProjectBundle.self, from: data)
        guard bundle.version <= ProjectBundle.currentVersion else {
            throw CodecError.unsupportedVersion(bundle.version)
        }
        return bundle
    }

    /// Suggested export filename for a project, sanitised for the filesystem.
    static func filename(for persona: Persona) -> String {
        let safe = persona.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = safe.isEmpty ? "project" : safe.lowercased()
        return "\(base).ogproject.json"
    }
}
