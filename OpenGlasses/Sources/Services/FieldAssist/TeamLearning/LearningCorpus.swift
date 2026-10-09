import Foundation

/// The retrieval side of an approved team learning (Plan FP §3): one document per entry per vault,
/// under `learning:<vaultId>` in `DocumentStore`, beside the vault's own namespace and outside its
/// manifest, baseline, ledger and manual removal.
///
/// - The document's **name** is the entry's contract §7.1 citation name, so
///   `VaultRetriever.Passage.citation` — no page, no section — renders exactly that.
/// - Its **text** is one chunk (`DocumentStore.ingestWhole`), so a finding is never split.
/// - Its **id** is the entry id joined to the vault id (`<entryID>@<vaultId>`). The plan said
///   `documentId` = `entryID`, but `documents.id` is the table's primary key, so one id cannot sit
///   in two vaults' namespaces; an entry with empty `vaultIDs` is in all of them. The entry id is
///   the first 32 characters and is read back with `entryID(fromDocumentId:)`.
///
/// Every operation is idempotent: publishing again replaces the same rows, withdrawing an entry
/// that is gone removes nothing, and `reconcile` makes the namespaces exactly what the live
/// entries say — the contract's whole-set replace (§6), which P3's set import will call.
@MainActor
enum LearningCorpus {

    /// The `sourceType` a learning document is stored with.
    nonisolated static let sourceType = "team_learning"

    /// One installed vault a learning may be published to, with the model index the entry's
    /// token is checked against (contract §7.2).
    struct VaultTarget: Equatable {
        let id: String
        let modelIndex: VaultModelIndex

        init(id: String, modelIndex: VaultModelIndex) {
            self.id = id
            self.modelIndex = modelIndex
        }

        /// Whether this vault knows the token as a model spelling.
        func knowsModel(_ token: String) -> Bool {
            guard let identity = VaultRetriever.ModelScope.identity(token) else { return false }
            return modelIndex.knownModelTokens.contains(identity)
        }
    }

    /// Where an entry goes, and where it is held back from.
    struct Placement: Equatable {
        /// Vaults whose namespace carries the entry's document.
        var published: [String] = []
        /// Vaults in the entry's scope whose model index does not know its token: flagged at
        /// review, never published blind (contract §7.2).
        var unknownModel: [String] = []
        /// Vaults the entry names that are not installed on this phone.
        var notInstalled: [String] = []
    }

    // MARK: - Ids

    nonisolated static func documentId(entryID: String, vaultId: String) -> String { "\(entryID)@\(vaultId)" }

    /// The entry id a corpus document id carries, or nil when it is not one.
    nonisolated static func entryID(fromDocumentId documentId: String) -> String? {
        guard let at = documentId.firstIndex(of: "@") else { return nil }
        let head = String(documentId[documentId.startIndex..<at])
        guard head.count == 32, head.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return head
    }

    // MARK: - The artefact

    /// The text a learning is retrieved and quoted by: the subject, then what was seen, worked out
    /// and done. Plain text; the citation travels as the document's name, not in the body.
    nonisolated static func documentText(_ entry: LearningEntry) -> String {
        var lines: [String] = []
        switch entry.subject {
        case .model(let token, _, _): lines.append("Model: \(token)")
        case .practice(let topic): lines.append("Practice: \(topic)")
        }
        if let symptom = entry.symptom, !symptom.isEmpty { lines.append("Symptom: \(symptom)") }
        lines.append("Finding: \(entry.finding)")
        if let fix = entry.fix, !fix.isEmpty { lines.append("Fix: \(fix)") }
        return lines.joined(separator: "\n")
    }

    /// The model token a learning document's first line names (`Model: <token>`), or nil for a
    /// practice entry. The artefact's own structured line, not prose: used only when the entry
    /// itself is not on this phone to ask.
    nonisolated static func subjectModelToken(fromDocumentText text: String) -> String? {
        guard let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              first.hasPrefix("Model: ") else { return nil }
        let token = first.dropFirst("Model: ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: - Placement

    nonisolated static func placement(of entry: LearningEntry, among vaults: [VaultTarget]) -> Placement {
        var placement = Placement()
        let installed = Set(vaults.map(\.id))
        placement.notInstalled = entry.vaultIDs.filter { !installed.contains($0) }
        guard entry.isLive else { return placement }
        for vault in vaults where entry.isScoped(to: vault.id) {
            if let token = entry.subject.modelToken, !vault.knowsModel(token) {
                placement.unknownModel.append(vault.id)
            } else {
                placement.published.append(vault.id)
            }
        }
        return placement
    }

    // MARK: - Writing

    /// Put one entry's document into every vault namespace it belongs in, and take it out of any
    /// learning namespace it no longer belongs in. A superseded or retracted entry belongs in none.
    @discardableResult
    static func publish(_ entry: LearningEntry, vaults: [VaultTarget], store: DocumentStore) -> Placement {
        let placement = placement(of: entry, among: vaults)
        let wanted = Set(placement.published.map { DocumentStore.learningNamespace($0) })
        for (documentId, namespace) in documents(of: entry.id, in: store) where !wanted.contains(namespace) {
            _ = try? store.forget(documentId: documentId, inNamespace: namespace)
        }
        let text = documentText(entry)
        for vaultId in placement.published {
            store.ingestWhole(documentId: documentId(entryID: entry.id, vaultId: vaultId),
                              name: entry.citationName, text: text, sourceType: sourceType,
                              namespace: DocumentStore.learningNamespace(vaultId))
        }
        return placement
    }

    /// Remove an entry's document from every learning namespace it is in. Returns how many
    /// documents went; 0 when it was already gone.
    @discardableResult
    static func withdraw(entryID: String, store: DocumentStore) -> Int {
        var removed = 0
        for (documentId, namespace) in documents(of: entryID, in: store) {
            if (try? store.forget(documentId: documentId, inNamespace: namespace)) != nil { removed += 1 }
        }
        return removed
    }

    /// Make every learning namespace exactly what `entries` say: each live entry's documents where
    /// it belongs, and nothing else — a document whose entry is absent, superseded or retracted
    /// leaves. Running it twice changes nothing the second time.
    static func reconcile(entries: [LearningEntry], vaults: [VaultTarget], store: DocumentStore) {
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for ref in store.list() where DocumentStore.isLearningNamespace(ref.namespace) {
            let owner = entryID(fromDocumentId: ref.id).flatMap { byId[$0] }
            if owner?.isLive != true {
                _ = try? store.forget(documentId: ref.id, inNamespace: ref.namespace)
            }
        }
        for entry in entries where entry.isLive {
            publish(entry, vaults: vaults, store: store)
        }
    }

    /// Every learning namespace emptied — the organisation's data leaving the phone.
    static func clearAll(store: DocumentStore) {
        let namespaces = Set(store.list().map(\.namespace).filter(DocumentStore.isLearningNamespace))
        for namespace in namespaces { store.clear(namespace: namespace) }
    }

    /// The (document id, namespace) pairs an entry occupies.
    static func documents(of entryID: String, in store: DocumentStore) -> [(String, String)] {
        store.list()
            .filter { DocumentStore.isLearningNamespace($0.namespace) && Self.entryID(fromDocumentId: $0.id) == entryID }
            .map { ($0.id, $0.namespace) }
    }
}
