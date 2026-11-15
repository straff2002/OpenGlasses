import Foundation

// The app types the retrieval sources reach that a command-line build doesn't need: the logging
// and file-protection calls become no-ops, the contextual-embedding switch is read from the
// environment (RETRIEVAL_EVAL_EMBEDDER=contextual) instead of the app's settings, and the app's
// downloaded search-trained model is never ready.

enum ManualStructure { static let diagramMarker = "<!-- page: diagram -->" }

enum Config {
    static var contextualEmbeddingEnabled: Bool {
        ProcessInfo.processInfo.environment["RETRIEVAL_EVAL_EMBEDDER"] == "contextual"
    }
    static var fieldAssistContextualSearchEnabled: Bool { contextualEmbeddingEnabled }
    static var fieldAssistManualSearchModel: ManualSearchModel { contextualEmbeddingEnabled ? .smarter : .standard }
}

// `SearchModelRuntime.swift` imports the `Tokenizers` package, which a plain `swiftc` can't link.
// The runner never goes through `Embedder.fieldAssist`: it builds `Embedder()` (standard or, with
// RETRIEVAL_EVAL_EMBEDDER=contextual, contextual) or the search-trained model from
// `SearchModel.swift`, whose tokens come from the reference tokenizer. So only the names
// `Embedder.swift` mentions are here, and the app's own copy of the model is never loaded.
enum ManualSearchModel: String { case standard, smarter, searchTrained }

enum SearchModelRuntime {
    static var ready: EmbeddingBackend? { nil }
    static func load() async -> Bool { false }
}

enum StoreProtection { static func applyDatabase(at url: URL) {} }

struct PrivacyToken { init(_ value: String) {} }

enum PrivacyLog {
    enum Store { case ragDocuments }
    enum Event { case opened, ingested, cleared, reembedded, openFailed, indexed, queryEmbedded }
    enum Failure { case sqlite(code: Int32, extended: Int32) }
    static func store(_ store: Store, _ event: Event, count: Int? = nil, total: Int? = nil, characters: Int? = nil,
                      error: Failure? = nil, detail: PrivacyToken? = nil, durationMs: Int? = nil) {}
}
