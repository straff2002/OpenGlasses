import Foundation

/// Equipment lookup for Field Assist: finds an error code, fault, or model number in the active
/// vault (error codes, manufacturer specs) and returns the matching reference section with its
/// source file, grounding the AI's diagnosis in the vault instead of free recall.
///
/// Two input paths:
///   - **Voice-first** (default): the technician reads the code/model aloud → `query`.
///   - **OCR** (when a camera is available and no `query` is given, or `use_camera` is set): the
///     nameplate/error display is read on-device via `OCRService`; candidate code/model tokens are
///     extracted and searched. Images never leave the device.
@MainActor
final class EquipmentLookupTool: NativeTool {
    let name = "equipment_lookup"
    let description = """
    Look up an equipment error code, fault, or model number in the active Field Assist vault. The \
    technician can read the code/model aloud (pass 'query'), or point the glasses at the nameplate / \
    error display and omit 'query' (or set 'use_camera') to read it via on-device OCR. Returns the \
    matching reference section with its source file. Use before diagnosing so the answer is grounded. \
    Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "The error code, fault, or model to look up (e.g. 'E5', 'Carrier 30RB'). Omit to read it from the camera."
            ],
            "use_camera": [
                "type": "boolean",
                "description": "Force reading the code/model from the glasses camera via OCR even if a query is given."
            ],
            "file": [
                "type": "string",
                "description": "Optional: restrict the search to a single vault file (e.g. 'error_codes.md')."
            ]
        ],
        "required": [] as [String]
    ]

    /// Files searched first, in priority order. Remaining vault files are searched after these.
    private static let priorityFiles = ["error_codes.md", "manufacturers.md"]

    private let cameraService: CameraService?
    private let ocr: OCRService
    /// Reference-tier fall-through: a code that lives only in an imported manual resolves here
    /// after the markdown core misses. Nil when no store was wired (headless contexts).
    private let documentStore: DocumentStore?
    /// Session to read the active vault from; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?

    init(cameraService: CameraService? = nil, ocr: OCRService = OCRService(),
         documentStore: DocumentStore? = nil, sessionService: FieldSessionService? = nil) {
        self.cameraService = cameraService
        self.ocr = ocr
        self.documentStore = documentStore
        self.injectedSession = sessionService
    }

    private var session: FieldSessionService { injectedSession ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to search its vault."
        }

        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceCamera = (args["use_camera"] as? Bool) ?? false
        let restrictTo = args["file"] as? String

        // Camera/OCR path when requested, or when no spoken query was provided.
        if (forceCamera || query == nil || query?.isEmpty == true) {
            guard cameraService != nil else {
                return "Specify what to look up (an error code, fault, or model number)."
            }
            return await lookupViaCamera(store: store, restrictTo: restrictTo)
        }

        if let hit = search(query: query!, store: store, restrictTo: restrictTo) { return hit }
        if let manual = manualFallback(query: query!, ocrText: nil, store: store) { return manual }
        return "No vault entry found for '\(query!)' in the \(store.manifest.name). Ask the technician for more detail, or recommend escalation rather than guessing."
    }

    // MARK: - Reference-tier fall-through

    /// Search the vault's imported manuals when the markdown core has nothing. Returns nil when the
    /// vault has no reference tier, nothing is ingested, or the evidence gate says insufficient —
    /// the caller's own miss message is the right answer then.
    private func manualFallback(query: String?, ocrText: String?, store: VaultStore) -> String? {
        guard store.manifest.hasDocuments, let documentStore else { return nil }
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        guard documentStore.documentCount(namespace: namespace) > 0 else { return nil }
        let retriever = VaultRetriever(query: { q, limit in
            documentStore.query(q, limit: limit, namespace: namespace)
        }, tokenSearch: { token, limit in
            documentStore.passages(containingToken: token, namespace: namespace, limit: limit)
        }, policy: session.retrievalPolicy)
        let outcome = retriever.retrieve(.init(turn: query, ocrText: ocrText, limit: 3))
        guard outcome.isSufficient else { return nil }
        return VaultRetriever.toolResult(outcome, query: query ?? "the label")
    }

    // MARK: - Camera path

    private func lookupViaCamera(store: VaultStore, restrictTo: String?) async -> String {
        guard let cameraService else {
            return "Camera not available. Ask the technician to read the code aloud."
        }
        let data: Data?
        if let frame = cameraService.latestFrame, let jpeg = frame.jpegData(compressionQuality: 0.9) {
            data = jpeg
        } else {
            data = try? await cameraService.capturePhoto()
        }
        guard let data else {
            return "Could not capture an image. Ask the technician to read the code aloud."
        }
        let ocrText = await ocr.recognizeText(in: data).text
        guard !ocrText.isEmpty else {
            return "I couldn't read any text on the label. Try moving closer or improving the lighting, or read the code aloud."
        }

        // Search each plausible code/model token from the OCR text.
        var matches: [(file: String, section: String)] = []
        for token in candidateTokens(from: ocrText) {
            if let result = searchMatches(query: token, store: store, restrictTo: restrictTo) {
                matches.append(contentsOf: result)
                if matches.count >= 3 { break }
            }
        }

        if matches.isEmpty {
            if let manual = manualFallback(query: nil, ocrText: ocrText, store: store) {
                return "Read from the label: \(ocrText.replacingOccurrences(of: "\n", with: " "))\n\n\(manual)"
            }
            return "Read this from the label via camera:\n\(ocrText)\n\n[No exact vault match. Identify the code/model from the text above and look it up, or ask the technician to confirm.]"
        }
        return render(Array(matches.prefix(3)), prefix: "Read from the label: \(ocrText.replacingOccurrences(of: "\n", with: " "))\n\n")
    }

    /// Plausible code/model tokens from OCR text — shared with manual retrieval via `CodeTokenizer`
    /// so both agree on what a code looks like. Kept as an instance method for existing callers.
    func candidateTokens(from text: String) -> [String] {
        CodeTokenizer.candidateTokens(from: text)
    }

    // MARK: - Search

    private func search(query: String, store: VaultStore, restrictTo: String?) -> String? {
        guard let matches = searchMatches(query: query, store: store, restrictTo: restrictTo) else { return nil }
        return render(matches, prefix: "")
    }

    private func searchMatches(query: String, store: VaultStore, restrictTo: String?) -> [(file: String, section: String)]? {
        let orderedFiles = orderedSearchFiles(manifestFiles: store.manifest.files, restrictTo: restrictTo)
        var matches: [(file: String, section: String)] = []
        for filename in orderedFiles {
            guard let contents = store.read(filename) else { continue }
            for section in matchingSections(in: contents, query: query) {
                matches.append((filename, section))
                if matches.count >= 3 { break }
            }
            if matches.count >= 3 { break }
        }
        return matches.isEmpty ? nil : matches
    }

    private func render(_ matches: [(file: String, section: String)], prefix: String) -> String {
        let rendered = matches.map { "=== \($0.file) ===\n\($0.section)" }.joined(separator: "\n\n")
        let citation = Set(matches.map { $0.file }).sorted().joined(separator: ", ")
        return "\(prefix)\(rendered)\n\n(Source: \(citation))"
    }

    private func orderedSearchFiles(manifestFiles: [String], restrictTo: String?) -> [String] {
        if let restrictTo { return [restrictTo] }
        let priority = Self.priorityFiles.filter { manifestFiles.contains($0) }
        let rest = manifestFiles.filter { !priority.contains($0) }
        return priority + rest
    }

    /// Split markdown into sections by `##`/`###` headings and return sections whose heading or body
    /// contains the query (case-insensitive). Matching is token-aware so "E5" doesn't match "E50".
    private func matchingSections(in markdown: String, query: String) -> [String] {
        let lowerQuery = query.lowercased()
        var sections: [String] = []
        var current: [String] = []

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { sections.append(joined) }
            current = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush()
            }
            current.append(String(line))
        }
        flush()

        return sections.filter { sectionMatches($0.lowercased(), query: lowerQuery) }
    }

    /// Contains check that rejects a match glued to a trailing alphanumeric, so a short code like
    /// "E5" doesn't match "E50". Checks every occurrence, not just the first.
    private func sectionMatches(_ haystack: String, query: String) -> Bool {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: query, range: searchStart..<haystack.endIndex) {
            let trailingOK: Bool
            if range.upperBound == haystack.endIndex {
                trailingOK = true
            } else {
                let after = haystack[range.upperBound]
                trailingOK = !(after.isLetter || after.isNumber)
            }
            if trailingOK { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
