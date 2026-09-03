import Foundation

/// Searches the OEM manuals imported into the active Field Assist vault (the reference tier) and
/// returns the relevant passages with machine-attached page citations — or the vault's fixed
/// insufficient-information sentence when nothing clears the evidence gate.
///
/// The per-turn prompt already carries passages for what the technician just said; this tool is
/// for follow-ups ("what does the manual say about the pressure switch?"), for widening a search
/// the model wants to run itself, and for reading a nameplate straight into a manual search.
@MainActor
final class ManualLookupTool: NativeTool {
    let name = "manual_lookup"
    let description = """
    Search the OEM manuals loaded into the active Field Assist vault for a fault code, model, \
    component, or procedure. Pass 'query' with what to look for, or omit it (or set 'use_camera') \
    to read a nameplate / fault display through the glasses camera and search on what it says. \
    Returns the matching manual passages, each with a Source line naming the manual and page — \
    cite those lines. If it reports that the manuals do not cover the question, say so rather than \
    answering from general knowledge. Requires an active session in a vault that has manuals.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "What to look up in the manuals (a fault code, model number, component, or question)."
            ],
            "document": [
                "type": "string",
                "description": "Optional: restrict the search to one manual by title (substring match)."
            ],
            "use_camera": [
                "type": "boolean",
                "description": "Read the nameplate or fault display via the camera and search on it."
            ]
        ],
        "required": [] as [String]
    ]

    private let documentStore: DocumentStore?
    private let cameraService: CameraService?
    private let ocr: OCRService
    /// Session to read the active vault from; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?

    init(documentStore: DocumentStore?, cameraService: CameraService? = nil, ocr: OCRService = OCRService(),
         sessionService: FieldSessionService? = nil) {
        self.documentStore = documentStore
        self.cameraService = cameraService
        self.ocr = ocr
        self.injectedSession = sessionService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to search its manuals."
        }
        guard store.manifest.hasDocuments else {
            return "The \(store.manifest.name) vault has no manuals. Its reference material is the vault core, which is already in context."
        }
        guard let documentStore else {
            return "Manual search is unavailable in this context."
        }
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        guard documentStore.documentCount(namespace: namespace) > 0 else {
            return "No manuals have been imported for the \(store.manifest.name) vault yet. Import them in Settings → Field Assist → Custom Vaults."
        }

        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceCamera = (args["use_camera"] as? Bool) ?? false
        let documentFilter = (args["document"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var ocrText: String?
        if forceCamera || query == nil || query?.isEmpty == true {
            guard let cameraService else {
                return "Specify what to look up in the manuals (a fault code, model, or component)."
            }
            let data: Data?
            if let frame = cameraService.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.9) {
                data = jpeg
            } else {
                data = try? await cameraService.capturePhoto()
            }
            guard let data else { return "Could not capture an image. Ask the technician to read the code aloud." }
            let text = await ocr.recognizeText(in: data).text
            guard !text.isEmpty else {
                return "I couldn't read any text on the label. Try moving closer or improving the lighting, or read the code aloud."
            }
            ocrText = text
        }

        let documentIds = documentFilter.flatMap { filter -> [String]? in
            let needle = filter.lowercased()
            guard !needle.isEmpty else { return nil }
            let ids = documentStore.list(namespace: namespace)
                .filter { $0.name.lowercased().contains(needle) }
                .map(\.id)
            return ids.isEmpty ? nil : ids
        }
        if let documentFilter, !documentFilter.isEmpty, documentIds == nil {
            let titles = documentStore.list(namespace: namespace).map { "\"\($0.name)\"" }.joined(separator: ", ")
            return "No manual titled like '\(documentFilter)'. Loaded manuals: \(titles)."
        }

        let retriever = VaultRetriever(query: { q, limit in
            documentStore.query(q, limit: limit, namespace: namespace, documentIds: documentIds)
        }, tokenSearch: { token, limit in
            documentStore.passages(containingToken: token, namespace: namespace, documentIds: documentIds, limit: limit)
        }, policy: session.retrievalPolicy)
        let outcome = retriever.retrieve(.init(turn: query, ocrText: ocrText,
                                               procedureStep: nil, limit: session.manualPassageLimit))
        let label = query.flatMap { $0.isEmpty ? nil : $0 } ?? "what the label says"
        var result = VaultRetriever.toolResult(outcome, query: label)
        if let ocrText {
            result = "Read from the label: \(ocrText.replacingOccurrences(of: "\n", with: " "))\n\n" + result
        }
        return result
    }
}
