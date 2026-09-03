import CryptoKit
import Foundation

/// Records which reference-tier documents a vault has ingested into `DocumentStore`, keyed by a
/// content hash, so import / re-import / delete keep the SQLite store and the vault folder in
/// agreement without the folder ever being the source of truth for chunks.
///
/// Lives in the vault's overlay directory as `_documents.json` — the overlay survives a baseline
/// re-push, which is exactly when the diff matters.
struct VaultDocumentLedger: Codable, Equatable {

    struct Entry: Codable, Equatable {
        let file: String
        let title: String
        let documentId: String
        let contentHash: String
        let chunkCount: Int
        /// Pages read by recognition rather than a text layer; nil on entries written before
        /// scanned import existed (which means zero).
        let ocrPages: Int?
        /// Of the recognised pages, how many fell below the confidence floor.
        let lowConfidencePages: Int?

        init(file: String, title: String, documentId: String, contentHash: String, chunkCount: Int,
             ocrPages: Int? = nil, lowConfidencePages: Int? = nil) {
            self.file = file
            self.title = title
            self.documentId = documentId
            self.contentHash = contentHash
            self.chunkCount = chunkCount
            self.ocrPages = ocrPages
            self.lowConfidencePages = lowConfidencePages
        }

        var usedRecognition: Bool { (ocrPages ?? 0) > 0 }
    }

    /// What the manifest wants installed, with the hash of the file as it is on disk now.
    struct Desired: Equatable {
        let file: String
        let title: String
        let contentHash: String
    }

    /// The work a sync has to do.
    struct Plan: Equatable {
        var unchanged: [Entry] = []
        var toForget: [Entry] = []
        var toIngest: [Desired] = []
        var isNoop: Bool { toForget.isEmpty && toIngest.isEmpty }
    }

    static let filename = "_documents.json"

    var entries: [Entry] = []

    init(entries: [Entry] = []) { self.entries = entries }

    // MARK: - Persistence

    static func load(from directory: URL) -> VaultDocumentLedger {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(VaultDocumentLedger.self, from: data) else {
            return VaultDocumentLedger()
        }
        return ledger
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }

    // MARK: - Diff

    /// Unchanged hash → keep. Changed hash → forget the old id, ingest anew. Missing from the
    /// manifest → forget. New → ingest.
    static func plan(current: VaultDocumentLedger, desired: [Desired]) -> Plan {
        var plan = Plan()
        let desiredByFile = Dictionary(uniqueKeysWithValues: desired.map { ($0.file, $0) })
        for entry in current.entries {
            guard let want = desiredByFile[entry.file] else { plan.toForget.append(entry); continue }
            if want.contentHash == entry.contentHash && want.title == entry.title {
                plan.unchanged.append(entry)
            } else {
                plan.toForget.append(entry)
                plan.toIngest.append(want)
            }
        }
        let known = Set(current.entries.map(\.file))
        for want in desired where !known.contains(want.file) {
            plan.toIngest.append(want)
        }
        return plan
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
