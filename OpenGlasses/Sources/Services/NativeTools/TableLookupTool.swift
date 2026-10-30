import Foundation

/// Reads one cell of a table extracted from the vault's own loaded manuals or code books (Plan JJ
/// P1): by table, row and column, with the cell's headers, units, notes and printed page, and a
/// `Source:` line that opens the table's page. Resolution is [[TableLookup]]'s, which never
/// interpolates, rounds, or picks a neighbouring row, and asks when the words fit more than one.
@MainActor
final class TableLookupTool: NativeTool {
    let name = "table_lookup"
    let description = """
    Read one value from a table printed in the manuals or code books loaded on this phone: the cell at a row and a column, with its row and column headings, units, the \
    notes it refers to, and the page it is printed on. Pass 'table' (its number as printed, e.g. \
    "Table 99", or words of its title), 'row' (the row's heading, e.g. a size, a type or a range, \
    or a number to find), and 'column' (the column's heading, e.g. "Rating group 2" or a path such \
    as "Rating group 2 › Band B"); leave 'column' out to read the whole row. Pass 'document' when \
    the technician names the book. If the number asked for falls between two rows it returns both \
    rows and says so: say both, and never interpolate, round, or pick the next row yourself. If it \
    asks which row, column, table or book, ask the technician. Read the value out as printed with \
    its row, column and page, and repeat the Source line. A value from a table printed as a picture \
    comes back marked "read from a picture of the table": say so, read it back for the technician \
    to check, and offer the page, and a cell the picture did not show clearly is never given, so \
    never supply it yourself. Uses your loaded manuals, or the active Field Assist session. In a personal library, name the manual when several are loaded; camera lookup requires Field Assist.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "table": [
                "type": "string",
                "description": "The table: its number as printed (\"Table 99\") or words of its title."
            ],
            "row": [
                "type": "string",
                "description": "The row: its heading as printed, a number to find, or words of the heading."
            ],
            "column": [
                "type": "string",
                "description": "Optional: the column heading, or a path of headings separated by ›. Leave out to read the whole row."
            ],
            "document": [
                "type": "string",
                "description": "Optional: the manual or code book the technician named, by title or part of it."
            ]
        ],
        "required": ["table", "row"]
    ]

    private let documentStore: DocumentStore?
    private let injectedSession: FieldSessionService?
    /// The technician's words this turn, for the edition a lookup reads (Plan IV P2).
    private let currentUtterance: @MainActor () -> String?

    init(documentStore: DocumentStore?, sessionService: FieldSessionService? = nil,
         currentUtterance: @escaping @MainActor () -> String? = { TechnicianWords.current() }) {
        self.documentStore = documentStore
        self.injectedSession = sessionService
        self.currentUtterance = currentUtterance
    }

    func execute(args: [String: Any]) async throws -> String {
        if !Config.fieldAssistActive {
            return PersonalManualLibrary.shared.table(args, documentStore: documentStore)
        }
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard let store = session.activeVault else {
            return "No active Field Assist session. Start a session to look up a table in its manuals."
        }
        guard VaultRegistry.shared.isUnlocked(store.manifest) else { return MyManualsPaywallCopy.locked }
        guard let documentStore else { return "Table lookup is unavailable in this context." }
        let table = (args["table"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let row = (args["row"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !table.isEmpty, !row.isEmpty else {
            return "Say which table ('table') and which row ('row') to read, and the column when the table has several."
        }
        let column = (args["column"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = (args["document"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refusal = Self.sizeRefusal(row: row, said: currentUtterance()) { return refusal }

        let sources = Self.sources(store: store, session: session, documentStore: documentStore,
                                   namedDocument: document?.isEmpty == false,
                                   said: [table, row, column, document, currentUtterance()].compactMap { $0 }.joined(separator: " "))
        let outcome = TableLookup.resolve(.init(table: table, row: row, column: column?.isEmpty == true ? nil : column,
                                                document: document), in: sources)
        noteForShowing(outcome, session: session, documentStore: documentStore)
        return TableLookup.render(outcome)
    }

    /// Why a lookup is refused before it runs (Plan KD P0): the technician said an aught size —
    /// "4/0", "four aught" — and the model passed the bare number it starts with, which is No. 4,
    /// a different conductor. Nil when the words name no aught size, when the row passed is one,
    /// or when the technician also said the bare number on its own. Pure.
    static func sizeRefusal(row: String, said: String?) -> String? {
        guard let said, let size = AWGSize.find(in: said), AWGSize.find(in: row) == nil else { return nil }
        var bare = row.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["no.", "no ", "#"] where bare.hasPrefix(prefix) {
            bare = String(bare.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard bare == String(size.prefix(1)) else { return nil }
        let withoutSizes = said.replacingOccurrences(of: #"[1-4]\s*/\s*0"#, with: " ", options: .regularExpression)
        guard !TechnicianRequest.words(withoutSizes).contains(bare) else { return nil }
        return "Not looked up: the technician said \(size), an aught size, and row \"\(row)\" is No. \(bare) — a "
            + "different conductor. Call again with row \"\(size)\"."
    }

    /// The vault's tables a lookup may read: its manuals' (never a team learning's, which has
    /// none), in documents still in the vault, of the newest edition unless the technician's words
    /// reach past it or a document is named.
    static func sources(store: VaultStore, session: FieldSessionService, documentStore: DocumentStore,
                        namedDocument: Bool, said: String) -> [TableLookup.Source] {
        let vaultId = store.manifest.id
        let available = VaultManualRemoval.availabilityCheck(forVault: vaultId, documentStore: documentStore,
                                                             capturedCatalog: session.capturedManuals)
        // Checks of tables read from a picture applied (Plan JN P3): a corrected cell is given as
        // checked, a disagreeing one is not given, and with the organisation's requirement an
        // unchecked one gives nothing.
        var stored = VaultTableChecks.applied(
            documentStore.storedTables(namespace: DocumentStore.vaultNamespace(vaultId)).filter { available($0.documentId) },
            checks: VaultTableChecks.checks(vaultId: vaultId),
            hashes: VaultTableChecks.documentHashes(VaultImporter.documentLedger(for: vaultId)),
            requireChecked: Config.organizationRequiresTableChecks)
        let editions = session.documentEditions(of: store)
        if !namedDocument,
           let titles = editions.searchableTitles(for: EditionRequest.parse(said, editions: editions),
                                                  among: Array(Set(stored.map(\.documentName)))) {
            stored = stored.filter { titles.contains($0.documentName) }
        }
        // The tables of the photographed manuals this job may read (Plan JN P4), with the phone's
        // checks of them, keyed by each captured revision's identity. Not an edition of a vault
        // manual, so never filtered by one.
        stored += capturedTables(vaultId: vaultId, session: session, documentStore: documentStore)
        return stored.map {
            TableLookup.Source(documentId: $0.documentId, documentName: $0.documentName, table: $0.table, termRule: $0.termRule)
        }
    }

    /// The stored tables of the photographed manuals eligible for the active job (Plan JN P4) — the
    /// catalog's own scope, policy and supersession rules decide which — with their checks applied.
    static func capturedTables(vaultId: String, session: FieldSessionService,
                               documentStore: DocumentStore) -> [DocumentStore.StoredTable] {
        let captured = session.capturedManuals.eligible(for: session.activeSession, vaultID: vaultId)
        guard !captured.isEmpty else { return [] }
        let stored = captured.flatMap { documentStore.storedTables(namespace: CapturedManualCatalog.namespace($0)) }
        guard !stored.isEmpty else { return [] }
        return VaultTableChecks.applied(stored, checks: VaultTableChecks.capturedChecks(vaultId: vaultId),
                                        hashes: CapturedManualTables.checkHashes(captured),
                                        requireChecked: Config.organizationRequiresTableChecks)
    }

    /// The stored row passages of the rows a set of lookups read, for "show me the table" to mark —
    /// a `rule_chain`'s lookups note theirs the same way (Plan JJ P2). None for a table read from a
    /// picture (Plan JN P2): its rows are not text on the page, so its region is outlined instead.
    static func rowPassages(for founds: [TableLookup.Found], documentStore: DocumentStore) -> [AnswerSourceMemory.Retrieved] {
        var out: [AnswerSourceMemory.Retrieved] = []
        for found in founds where !found.source.table.source.isRecognised {
            let table = found.source.table
            let wanted = Set(found.rows.compactMap { TableRowPassage.sentence(for: $0, in: table) })
            out += documentStore.passages(figure: table.label, documentIds: [found.source.documentId], limit: Int.max)
                .filter { $0.kind == .tableRow && wanted.contains($0.text) }
                .map {
                    AnswerSourceMemory.Retrieved(documentId: $0.documentId, documentName: $0.documentName,
                                                 chunkIndex: $0.chunkIndex, page: $0.page, section: $0.section, text: $0.text,
                                                 figure: $0.figure, isTableRow: true)
                }
        }
        return out
    }

    /// What "show me the table" opens next: the cited pages, each marking the row it was read from
    /// or, for a table read from a picture, outlining where the picture was read (Plan JN P2).
    private func noteForShowing(_ outcome: TableLookup.Outcome, session: FieldSessionService,
                                documentStore: DocumentStore) {
        let sessionId = session.activeSession?.id
        // The table read is the one a retrieved page may go to the model under (Plan KD P3).
        switch outcome {
        case .found(let found): session.noteLookedUpTable(found.source.table.label)
        case .notExtracted(let source), .unclear(let source, _, _): session.noteLookedUpTable(source.table.label)
        case .ambiguous, .notFound, .noTables: break
        }
        switch outcome {
        case .found(let found):
            let table = found.source.table
            session.sourceCenter.noteTableLookup(
                rows: Self.rowPassages(for: [found], documentStore: documentStore),
                citations: TableLookup.citations(documentName: found.source.documentName, label: table.label,
                                                 pages: TableLookup.pages(of: found)),
                pictureAreas: table.pictureAreas,
                sessionId: sessionId)
        case .notExtracted(let source):
            session.sourceCenter.noteTableLookup(
                rows: [],
                citations: TableLookup.citations(documentName: source.documentName, label: source.table.label,
                                                 pages: [source.table.page]),
                sessionId: sessionId)
        case .unclear(let source, let pages, _):
            session.sourceCenter.noteTableLookup(
                rows: [],
                citations: TableLookup.citations(documentName: source.documentName, label: source.table.label,
                                                 pages: pages),
                pictureAreas: source.table.pictureAreas,
                sessionId: sessionId)
        case .ambiguous, .notFound, .noTables:
            break
        }
    }
}
