import Foundation

/// Plan LW §7 — the manuals a vault was written against, as its export states them (`expects`), pure.
///
/// Each of the vault's documents becomes one entry: its **key**, the title, the edition when the
/// manifest gives one, and the `revision` (SHA-256 of the file, lowercase hex) when it is known: the
/// document's own `revision` (Plan LV), else the hash the document ledger recorded when the manual
/// was indexed, which is the same digest of the same bytes and already on the phone. The shape is
/// `CompanyVaultContract.ExpectedManual`'s, which Plan LV's catalog row and checklist read.
///
/// **The key** is what the vault's index rows cite (`IndexRowWriter`: `key p. N`), so it must come
/// out the same every time the vault is exported, on any phone. It is made from the document's file
/// name, which the manifest keeps and an import of the export asks for by name: lowercase ASCII
/// letters and digits, every other run one hyphen, the extension left off. Two files that would share
/// a key keep their extensions in it; a clash beyond that takes a number, in manifest order.
///
/// A vault with no documents has no `expects`, and its export is the bytes it always was.
enum VaultExpects {

    /// The contract's limits (`CompanyVaultCatalog.publishingFieldsAreSound`).
    static let maximumEntries = CompanyVaultCatalog.maximumExpectsPerVault
    static let maximumTitleLength = 200
    static let maximumEditionLength = 80
    static let maximumKeyLength = 80

    static func expects(for documents: [VaultDocument], ledgerHashes: [String: String] = [:])
        -> [CompanyVaultCatalog.ExpectedManual] {
        let keys = keys(forFiles: documents.map(\.file))
        return zip(documents, keys).prefix(maximumEntries).map { document, key in
            let title = String(document.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumTitleLength))
            let edition = document.edition.map { String($0.trimmingCharacters(in: .whitespaces).prefix(maximumEditionLength)) }
            let revision = [document.revision, ledgerHashes[document.file]].compactMap { $0 }.first(where: isDigest)
            return CompanyVaultCatalog.ExpectedManual(key: key, title: title.isEmpty ? document.file : title,
                                                      edition: edition?.isEmpty == false ? edition : nil,
                                                      revision: revision)
        }
    }

    /// The ledger's hashes by document file.
    static func ledgerHashes(_ ledger: VaultDocumentLedger) -> [String: String] {
        Dictionary(ledger.entries.map { ($0.file, $0.contentHash) }, uniquingKeysWith: { first, _ in first })
    }

    /// The key a document's index rows cite, among the vault's documents `files`.
    static func key(forFile file: String, among files: [String]) -> String? {
        guard let index = files.firstIndex(of: file) else { return nil }
        return keys(forFiles: files)[index]
    }

    /// One key per file, in order, each unique and a safe identifier.
    static func keys(forFiles files: [String]) -> [String] {
        let stems = files.map { slug(($0 as NSString).deletingPathExtension) }
        let stemCounts = Dictionary(stems.map { ($0, 1) }, uniquingKeysWith: +)
        let preferred = zip(files, stems).map { file, stem in
            stemCounts[stem, default: 0] > 1 ? slug(file) : stem
        }
        var taken = Set<String>()
        return preferred.map { key in
            var candidate = key
            var number = 2
            while taken.contains(candidate) {
                let suffix = "-\(number)"
                candidate = String(key.prefix(maximumKeyLength - suffix.count)) + suffix
                number += 1
            }
            taken.insert(candidate)
            return candidate
        }
    }

    /// Lowercase ASCII letters and digits, every other run a single hyphen, none at either end, at
    /// most 80 characters. `manual` when nothing is left.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        var capped = String(out.prefix(maximumKeyLength))
        while capped.hasSuffix("-") { capped.removeLast() }
        return capped.isEmpty ? "manual" : capped
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
