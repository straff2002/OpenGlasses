import Foundation

/// Plan LW §6 — the vault check, run on the phone: the trade's starter questions and the author's
/// own, each asked of the vault's real retrieval (the session's own retriever, no model and no
/// network), scored by `VaultCheck`.
enum VaultCheckRunner {

    /// The questions to ask: the template's starter set with the pages the author picked for them,
    /// then the author's own.
    static func questions(template: TradeTemplate, record: VaultAuthoringRecord?) -> [VaultCheck.Question] {
        let answers = (record?.starterAnswers ?? [:]).mapValues { [VaultCheck.PageRef(key: $0.key, page: $0.page)] }
        let starters = VaultCheck.starterQuestions(template, answers: answers)
        let own = (record?.questions ?? []).map {
            VaultCheck.Question(text: $0.text, expected: [VaultCheck.PageRef(key: $0.key, page: $0.page)])
        }
        return starters + own
    }

    /// One passage as the score reads it: its manual's key (by its document id) and every PDF page it
    /// covers, its own page and those a chunk packed across. A passage of no manual of the vault (a
    /// team learning) keeps its document's name, which matches no expected page.
    static func retrieved(_ passages: [VaultRetriever.Passage], keyForDocument: (String) -> String?) -> [VaultCheck.Retrieved] {
        passages.map { passage in
            var pages = passage.page.map { [$0] } ?? []
            for pageBreak in passage.pageBreaks where !pages.contains(pageBreak.page) { pages.append(pageBreak.page) }
            return VaultCheck.Retrieved(key: keyForDocument(passage.documentId) ?? passage.documentName, pages: pages)
        }
    }

    /// The manual keys of the vault's documents, by the document id indexing gave each.
    static func keysByDocumentId(manifest: VaultManifest, ledger: VaultDocumentLedger) -> [String: String] {
        let files = manifest.documents.map(\.file)
        var out: [String: String] = [:]
        for entry in ledger.entries {
            if let key = VaultExpects.key(forFile: entry.file, among: files) { out[entry.documentId] = key }
        }
        return out
    }

    /// Ask every question of the vault and score it. Retrieval only.
    @MainActor
    static func run(manifest: VaultManifest, documentStore: DocumentStore,
                    questions: [VaultCheck.Question]) -> VaultCheck.Score {
        let store = VaultRegistry.shared.store(for: manifest)
        let retriever = FieldSessionService.shared.makeRetriever(store: store, documentStore: documentStore)
        let keys = keysByDocumentId(manifest: manifest, ledger: VaultImporter.documentLedger(for: manifest.id))
        let results = questions.map { question -> [VaultCheck.Retrieved] in
            let passages = retriever.retrieve(.init(turn: question.text, limit: VaultCheck.defaultDepth)).passages
            return retrieved(passages, keyForDocument: { keys[$0] })
        }
        return VaultCheck.score(questions, retrieved: results)
    }
}
