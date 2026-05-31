import Foundation

/// Lets the agent build and query a private, on-device document knowledge base.
///
/// Documents are chunked, embedded, and stored locally ([[DocumentStore]]). On `query`, the most
/// relevant passages are returned **as the tool result** with source attribution — the model then
/// answers grounded in them. The tool deliberately does not answer itself.
struct DocumentRAGTool: NativeTool {
    let name = "document_knowledge"
    let description = """
    Build and search a private on-device knowledge base of the user's documents. \
    Use 'query' to retrieve relevant passages from previously saved documents before answering \
    questions about a manual, contract, report, or any saved text — answer grounded in what comes back. \
    Use 'ingest_scan' to capture and save a document the user is looking at through the glasses \
    ("remember this document", "save this manual"). Use 'ingest_text' to save provided/dictated text. \
    Use 'list' to see saved documents and 'forget' to delete one. All content stays on-device.
    """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["query", "ingest_scan", "ingest_text", "list", "forget"],
                "description": "What to do. Default 'query'."
            ],
            "query": [
                "type": "string",
                "description": "For 'query': the question or topic to retrieve passages about."
            ],
            "text": [
                "type": "string",
                "description": "For 'ingest_text': the document text to save."
            ],
            "name": [
                "type": "string",
                "description": "A label for the document (ingest), or the document to delete (forget)."
            ],
            "document_id": [
                "type": "string",
                "description": "Optional. Scope a 'query' to one document, or identify a document to 'forget'."
            ],
            "limit": [
                "type": "integer",
                "description": "For 'query': max passages to return (default 4, max 10)."
            ]
        ],
        "required": ["action"]
    ]

    weak var documentStore: DocumentStore?
    var cameraService: CameraService?
    var ocrService = OCRService()

    func execute(args: [String: Any]) async throws -> String {
        guard let store = documentStore else { return "Document knowledge base is unavailable." }
        let action = (args["action"] as? String)?.lowercased() ?? "query"

        switch action {
        case "query":   return await runQuery(args, store: store)
        case "ingest_text": return await ingestText(args, store: store)
        case "ingest_scan": return await ingestScan(args, store: store)
        case "list":    return listDocuments(store: store)
        case "forget":  return forget(args, store: store)
        default:        return "Unknown action '\(action)'. Use query, ingest_scan, ingest_text, list, or forget."
        }
    }

    // MARK: - Actions

    private func runQuery(_ args: [String: Any], store: DocumentStore) async -> String {
        let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Provide a query to search the document knowledge base." }
        guard !store.list().isEmpty else {
            return "No documents have been saved yet. Use ingest_scan or ingest_text to add one first."
        }

        let limit = min(max(args["limit"] as? Int ?? 4, 1), 10)
        let docId = (args["document_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let passages = store.query(query, limit: limit, documentIds: docId.map { [$0] })

        guard !passages.isEmpty else {
            return "No relevant passages found for: \(query)"
        }

        let body = passages.enumerated().map { i, p in
            "[\(i + 1)] From \"\(p.documentName)\" (\(locator(for: p)), score \(String(format: "%.2f", p.similarity))):\n\(p.text)"
        }.joined(separator: "\n\n")

        return "Relevant passages for '\(query)' — answer using only these, and cite the document name and (when shown) the page/section:\n\n\(body)"
    }

    /// A speakable source locator for a passage: prefers page + section, degrades to whichever is
    /// present, and falls back to the chunk index when the document carried no page/heading markers.
    private func locator(for p: DocumentStore.Passage) -> String {
        var parts: [String] = []
        if let page = p.page { parts.append("page \(page)") }
        if let section = p.section, !section.isEmpty { parts.append(section) }
        return parts.isEmpty ? "chunk \(p.chunkIndex)" : parts.joined(separator: ", ")
    }

    private func ingestText(_ args: [String: Any], store: DocumentStore) async -> String {
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Provide text to save as a document." }
        let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName(prefix: "Note")

        guard let ref = await store.ingest(name: name, text: text, sourceType: "text") else {
            return "Could not save the document — the text may be too short."
        }
        return "Saved \"\(ref.name)\" to your knowledge base (\(ref.chunkCount) sections, \(ref.charCount) characters)."
    }

    private func ingestScan(_ args: [String: Any], store: DocumentStore) async -> String {
        guard let camera = cameraService else {
            return "Scanning is unavailable — no camera connected."
        }

        let photoData: Data
        do {
            photoData = try await camera.capturePhoto()
        } catch {
            return "Could not capture from the glasses camera: \(error.localizedDescription). Make sure glasses are connected."
        }

        let result = await ocrService.recognizeText(in: photoData)
        guard !result.isEmpty else {
            return "No readable text found in the image. Try holding the document closer or in better light."
        }

        let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultName(prefix: "Scan")
        guard let ref = await store.ingest(name: name, text: result.text, sourceType: "scan") else {
            return "Captured text but could not save it."
        }
        return "Scanned and saved \"\(ref.name)\" (\(ref.chunkCount) sections, \(ref.charCount) characters). You can now ask questions about it."
    }

    private func listDocuments(store: DocumentStore) -> String {
        let docs = store.list()
        guard !docs.isEmpty else { return "No documents saved yet." }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let lines = docs.map { "- \"\($0.name)\" [\($0.sourceType)] — \($0.chunkCount) sections, saved \(df.string(from: $0.createdAt)) (id: \($0.id))" }
        return "Saved documents (\(docs.count)):\n" + lines.joined(separator: "\n")
    }

    private func forget(_ args: [String: Any], store: DocumentStore) -> String {
        let docs = store.list()
        guard !docs.isEmpty else { return "No documents to delete." }

        if let id = (args["document_id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
           let match = docs.first(where: { $0.id == id }) {
            store.forget(documentId: match.id)
            return "Deleted \"\(match.name)\" from your knowledge base."
        }
        if let name = (args["name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            let matches = docs.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard let match = matches.first else {
                return "No saved document named \"\(name)\". Use list to see saved documents."
            }
            store.forget(documentId: match.id)
            return "Deleted \"\(match.name)\" from your knowledge base."
        }
        return "Specify which document to delete by name or document_id. Use list to see them."
    }

    // MARK: - Helpers

    private func defaultName(prefix: String) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return "\(prefix) \(df.string(from: Date()))"
    }
}
