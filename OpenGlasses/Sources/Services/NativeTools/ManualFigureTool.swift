import Foundation

/// Puts a numbered drawing from the vault's manuals in front of the technician, and on the next
/// turn's image slot for the model (Plan EK P2).
///
/// The automatic path already stages the drawing a turn's own evidence points at. This tool is the
/// asked-for path — "show me figure 65", "what's on page 44", "show that figure again" — which is
/// how a technician gets a diagram they know the number of without phrasing a question that
/// happens to retrieve it.
@MainActor
final class ManualFigureTool: NativeTool {
    let name = "manual_figure"
    let description = """
    Show a numbered figure, table or page from the manuals loaded into the active Field Assist \
    vault. Pass 'figure' ("Figure 58", or just "58"), or 'page' with a printed page number, or \
    'again' to bring back the last figure shown. The page opens on the technician's phone and is \
    attached to your next turn as an image when one is available, so you can read the drawing \
    yourself. Use it when the technician names a figure or asks to see a wiring diagram, and after \
    citing one. A manual imported as extracted text has no page to show — the tool says so, and \
    the citation is still correct. Requires an active session in a vault that has manuals.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "figure": [
                "type": "string",
                "description": "The figure or table to show, e.g. \"Figure 58\", \"Table 16\", or just \"58\"."
            ],
            "page": [
                "type": "integer",
                "description": "The printed page number to show, when the technician names a page rather than a figure."
            ],
            "again": [
                "type": "boolean",
                "description": "Show the last figure again (\"show that figure again\")."
            ]
        ],
        "required": [] as [String]
    ]

    private let documentStore: DocumentStore?
    /// Session to stage on; nil means the shared service. Injectable for tests.
    private let injectedSession: FieldSessionService?

    init(documentStore: DocumentStore?, sessionService: FieldSessionService? = nil) {
        self.documentStore = documentStore
        self.injectedSession = sessionService
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to show a figure from its manuals."
        }

        if (args["again"] as? Bool) == true {
            guard let staged = session.restageLastFigure() else {
                return "No figure has been shown yet in this session. Name a figure or a page number."
            }
            return show(staged, session: session, opening: "Back to")
        }

        guard store.manifest.hasDocuments, let documentStore else {
            return "The \(store.manifest.name) vault has no manuals to show figures from."
        }
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        guard documentStore.documentCount(namespace: namespace) > 0 else {
            return "No manuals have been imported for the \(store.manifest.name) vault yet. Import them in Settings → Field Assist → Custom Vaults."
        }

        let requestedFigure = (args["figure"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPage = Self.integer(args["page"])

        var passage: VaultRetriever.Passage?
        if let requestedFigure, !requestedFigure.isEmpty {
            for label in Self.candidateLabels(for: requestedFigure) {
                if let hit = documentStore.passages(figure: label, namespace: namespace, limit: 1).first {
                    passage = Self.retrieved(hit)
                    break
                }
            }
            guard passage != nil else {
                return "No \(requestedFigure) in the manuals loaded for this vault. Ask for it by page number, or search the manuals with manual_lookup."
            }
        } else if let requestedPage {
            guard let hit = documentStore.passages(onPage: requestedPage, namespace: namespace, limit: 1).first else {
                return "Nothing is stored for page \(requestedPage) of the loaded manuals."
            }
            passage = Self.retrieved(hit)
        } else {
            return "Name the figure to show (\"Figure 58\"), a page number, or ask for the last one again."
        }

        guard let staged = session.makeStagedFigure(for: passage, vaultId: store.manifest.id) else {
            return "That passage has no page number, so there is no page to show."
        }
        session.stageFigure(staged)
        return show(staged, session: session, opening: "Showing")
    }

    // MARK: - Staging → phone, lens, and the answer

    /// Staging is what shows the figure: the app subscribes to the session and opens the sheet,
    /// flashes the lens cue and writes the audit line. All this does is say what happened, so a
    /// headless caller gets the same answer without an app around it.
    private func show(_ staged: FieldSessionService.StagedFigure,
                      session: FieldSessionService, opening: String) -> String {
        let presenter = ManualFigurePresenter(figure: staged, sourceURL: session.sourcePDFURL(for: staged))
        var lines = ["\(opening) \(staged.name) on the technician's phone. Source: \(staged.citation)."]
        if presenter.hasPicture {
            lines.append("The page is attached to your next turn as an image, so read the drawing there rather than describing it from the labels.")
        } else {
            lines.append("The figure is cited but this document was imported as text, so there is no page to show; import the PDF to see it.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Parsing

    /// The captions a spoken request could mean. "58" is the common case — a technician reads the
    /// number off the page and says it — and a drawing is far likelier than a table, so the figure
    /// is tried first.
    static func candidateLabels(for request: String) -> [String] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = trimmed.range(of: #"\d+"#, options: .regularExpression).map({ String(trimmed[$0]) }) else {
            return []
        }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("table") { return ["Table \(number)"] }
        if lowered.hasPrefix("figure") || lowered.hasPrefix("fig") { return ["Figure \(number)"] }
        return ["Figure \(number)", "Table \(number)"]
    }

    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A store passage as the retriever's passage type, so staging has one input shape whether it
    /// came from a ranked turn or from an exact lookup.
    private static func retrieved(_ p: DocumentStore.Passage) -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: p.documentId, documentName: p.documentName,
                               chunkIndex: p.chunkIndex, text: p.text, page: p.page, section: p.section,
                               similarity: p.similarity, score: p.similarity, matchedTokens: [],
                               kind: p.kind, figure: p.figure)
    }
}
