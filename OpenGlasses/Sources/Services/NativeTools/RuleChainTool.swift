import Foundation

/// Runs a rule chain the active vault offers (Plan JJ P2): a sequence the organisation wrote in
/// its `chains.md` that asks the technician for values, looks cells up in the tables extracted from
/// the vault's own loaded manuals, does the arithmetic and a check, and reads every step back with
/// its citation. [[ChainRunner]] keeps the state and never goes past a step it could not complete;
/// the current question is in the system prompt (`FieldSessionService.chainPromptContext`), so the
/// model asks in its own words. A finished or stopped chain files its read-back on the job as a
/// reading, and its lookups' pages are what "show me the table" opens.
///
/// Since P3 it also runs the chain the model proposed with `propose_chain` once the technician says
/// go, and chains kept on this phone, each marked unreviewed wherever it is said or filed; `keep`
/// keeps a proposed chain that ran to a result, and `share` hands the kept chains to the share
/// sheet as a `chains.md` fragment, so an organisation with no office can add them by hand.
///
/// Not offered to Apple's on-device model (decision 7): a chain's steps and read-back do not fit
/// that window.
@MainActor
final class RuleChainTool: NativeTool {
    let name = "rule_chain"
    let description = """
    Run a rule chain the active Field Assist vault offers: steps its organisation wrote that ask the \
    technician for values, look cells up in the tables of the loaded code books, do the arithmetic \
    and a check, and read every step back with its table, row, column and page — for example sizing \
    a conductor for a load, or checking whether an installed one carries it. It also runs a chain \
    proposed with propose_chain once the technician says go, and chains kept on this phone; both are \
    unreviewed, so say so. Actions: 'list' (the chains by name: read the names out), 'start' (pass \
    'chain', its name; it replaces a chain already running; only when the technician asks for that \
    chain, asks to run a chain, or says yes to the one you offered), 'answer' (pass 'value', the technician's reply to the current question, as said), \
    'status', 'stop', 'keep' (keep the proposed chain that just ran to a result on this phone, when \
    the technician asks), 'share' (the kept chains as a chains.md file, by the share sheet). The \
    current question is in the system prompt: ask it in your own words. Never pass a value the \
    technician did not say, and never work a step yourself. When it finishes, say the result and \
    read back the steps with their pages; when it stops it has ended: say why, offer to show the page \
    and ask for no more of its values. Offer a chain by name when one answers the question; never \
    start one the technician did not ask for. \
    Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "'list', 'start', 'answer', 'status', 'stop', 'keep' or 'share'."
            ],
            "chain": [
                "type": "string",
                "description": "On 'start': the chain's name as 'list' gives it."
            ],
            "value": [
                "type": "string",
                "description": "On 'answer': what the technician said, e.g. \"32\", \"14 °C\" or a size as printed."
            ]
        ],
        "required": ["action"]
    ]

    private let documentStore: DocumentStore?
    private let injectedSession: FieldSessionService?
    /// The delivery rules in force, for whether the share sheet may be used. Injectable so a test
    /// does not depend on this device's settings.
    private let settings: () -> DeliverySettings
    /// Where the shared fragment's file is staged.
    private let injectedExports: StagedExportCoordinator?
    /// The technician's words this turn, and what the assistant said before them: a chain starts
    /// only when those words ask for it (Plan KD P0).
    private let currentUtterance: @MainActor () -> String?
    private let previousReply: @MainActor () -> String?

    init(documentStore: DocumentStore?, sessionService: FieldSessionService? = nil,
         settings: @escaping () -> DeliverySettings = { DeliverySettings.load() },
         exports: StagedExportCoordinator? = nil,
         currentUtterance: @escaping @MainActor () -> String? = { TechnicianWords.current() },
         previousReply: @escaping @MainActor () -> String? = { TechnicianWords.previousReply() }) {
        self.documentStore = documentStore
        self.injectedSession = sessionService
        self.settings = settings
        self.injectedExports = exports
        self.currentUtterance = currentUtterance
        self.previousReply = previousReply
    }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let actions = "'list', 'start', 'answer', 'status', 'stop', 'keep' or 'share'"
        guard let action = (args["action"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return "No action given. Use \(actions)."
        }
        let session = injectedSession ?? FieldSessionService.shared
        guard session.activeSession != nil else {
            return FieldSessionService.ChainError.noSession.errorDescription ?? ""
        }
        switch action {
        case "list": return list(session)
        case "start": return start(args: args, session: session)
        case "answer": return answer(args: args, session: session)
        case "status": return status(session)
        case "stop", "cancel":
            guard let run = session.stopChain() else { return "No rule chain is running." }
            return "Stopped the chain '\(run.chain.name)' at step \(run.state.position + 1). Nothing was recorded on the job."
        case "keep", "save": return keep(session)
        case "share": return share(session)
        default:
            return "Unknown action '\(action)'. Use \(actions)."
        }
    }

    // MARK: - Actions

    private func tables(_ session: FieldSessionService) -> [TableLookup.Source] {
        guard documentStore != nil else { return [] }
        return session.chainTables(documentStore: documentStore)
    }

    /// Plan JW P0: the names first, one per line and exactly as 'start' takes them, because a chain
    /// is started by its name and the technician has to hear the names to pick one. Each line
    /// carries only a short mark — unreviewed, or that it cannot start for want of a table; what a
    /// chain answers is in the system prompt. The old list, every chain with its "answers" text,
    /// ran to thousands of characters for a vault of a dozen chains and was summarised as
    /// categories, so no name was ever said.
    private func list(_ session: FieldSessionService) -> String {
        let vault = session.vaultChains
        let offered = session.offeredChains
        guard !offered.isEmpty else {
            return vault.problems.isEmpty
                ? "This vault offers no rule chains."
                : "This vault's chains.md has \(vault.problems.count) problem(s), so none of its chains is offered: "
                    + vault.problems.prefix(3).map(\.description).joined(separator: "; ")
        }
        let tables = self.tables(session)
        var lines = ["Rule chains in this vault, by name:"]
        for entry in offered {
            var marks: [String] = []
            switch entry.origin {
            case .authored: break
            case .kept: marks.append(ChainOrigin.kept.marking ?? "")
            case .proposed: marks.append((ChainOrigin.proposed.marking ?? "") + ": waiting for the technician's go")
            }
            let unreadable = Self.unreadableTables(entry.chain, tables: tables)
            if !unreadable.isEmpty {
                marks.append("can't start: needs " + unreadable.map(\.label).joined(separator: ", "))
            }
            lines.append("• " + entry.chain.name + (marks.isEmpty ? "" : " (" + marks.joined(separator: "; ") + ")"))
        }
        lines.append("Read these names to the technician as they are: a chain is started by its name. "
                     + "What each one answers is in the system prompt.")
        if !vault.problems.isEmpty {
            lines.append("\(vault.problems.count) chain problem(s) in chains.md keep some chains out.")
        }
        return lines.joined(separator: "\n")
    }

    /// A table a chain reads that it cannot: not among the loaded manuals' tables at all, or
    /// found by its caption with a grid that could not be read.
    struct UnreadableTable: Equatable {
        let label: String
        /// The table as found, when its caption was; nil when no loaded manual prints it.
        let source: TableLookup.Source?
    }

    /// The tables `chain` names that no loaded manual lets it read, in the chain's order (Plan JW
    /// P0). A chain that needs one stops at that step, so it is not started at all. Pure.
    static func unreadableTables(_ chain: ChainDefinition, tables: [TableLookup.Source]) -> [UnreadableTable] {
        chain.tableLabels.compactMap { label in
            let holding = tables.filter { $0.table.label.caseInsensitiveCompare(label) == .orderedSame }
            if holding.isEmpty { return UnreadableTable(label: label, source: nil) }
            if holding.contains(where: \.table.isExtracted) { return nil }
            return UnreadableTable(label: label, source: holding.first)
        }
    }

    private func start(args: [String: Any], session: FieldSessionService) -> String {
        let asked = (args["chain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let offered = session.offeredChains
        let names = offered.map(\.chain.name)
        guard !asked.isEmpty else {
            return "Say which chain ('chain'). " + (names.isEmpty ? "This vault offers none." : "Chains: " + names.joined(separator: "; ") + ".")
        }
        let matches = VaultChains(chains: offered.map(\.chain)).chains(named: asked)
        guard matches.count == 1, let chain = matches.first,
              let entry = offered.first(where: { $0.chain.name == chain.name }) else {
            if matches.isEmpty {
                return "No chain is named like \"\(asked)\". "
                    + (names.isEmpty ? "This vault offers none." : "Chains: " + names.joined(separator: "; ") + ".")
            }
            return "More than one chain fits \"\(asked)\": " + matches.map(\.name).joined(separator: "; ")
                + ". Ask the technician which."
        }
        // The same chain again (Plan JW P0): it carries on where it is, never restarted.
        if let running = session.activeChain, running.chain.name == chain.name {
            var lines = ["The chain '\(chain.name)' is already running, at step \(running.state.position + 1) of "
                         + "\(running.chain.steps.count). It was not restarted."]
            if case .ask(let ask) = running.current { lines.append(Self.askLine(ask)) }
            return lines.joined(separator: "\n")
        }
        // Asked for, or not started (Plan KD P0) — a new chain and one that replaces a running
        // chain alike, so a question about something else never stops the chain in hand either.
        if let refusal = Self.startRefusal(chain: chain.name, said: currentUtterance(), previousReply: previousReply(),
                                           proposed: session.pendingProposal?.proposal.chain.name) {
            return refusal
        }
        let tables = self.tables(session)
        // A chain that cannot read one of its tables would ask its questions and then stop at that
        // step (Plan JW P0): it is refused before anything starts, and a running chain is left alone.
        let unreadable = Self.unreadableTables(chain, tables: tables)
        if !unreadable.isEmpty {
            noteUnreadable(unreadable, session: session)
            return Self.refusal(chain, unreadable: unreadable)
        }
        // The technician named a chain to start: one already running is stopped, exactly as 'stop'
        // stops it — nothing recorded — and the named one starts (Plan JW P0, owner decision).
        var lines: [String] = []
        if let replaced = session.activeChain {
            session.stopChain()
            lines.append("Stopped '\(replaced.chain.name)' at step \(replaced.state.position + 1); nothing was recorded.")
        }
        do {
            let progress = try session.startChain(chain, tables: tables, origin: entry.origin,
                                                  sources: entry.sources)
            note(progress, session: session)
            let marked = entry.origin.marking.map { " (\($0))" } ?? ""
            lines.append("Started the chain '\(chain.name)'\(marked).\n" + present(progress))
            return lines.joined(separator: " ")
        } catch {
            return (lines + [error.localizedDescription]).joined(separator: " ")
        }
    }

    /// Why the model's `start` is refused, or nil when the technician asked for the chain (Plan KD
    /// P0): their words name it, ask to run a chain, or say yes to the chain offered last turn —
    /// named in the assistant's last reply, or the proposal read back and waiting for go. The
    /// partner's retest had a chain start on a question it happened to answer, because the
    /// prompt told the model to start one whenever a chain fits. A turn with no captured words (a
    /// live session) is not gated, as `TechnicianWords` documents. Pure.
    static func startRefusal(chain name: String, said: String?, previousReply: String?, proposed: String?) -> String? {
        guard let said else { return nil }
        if TechnicianRequest.names(chain: name, in: said) || TechnicianRequest.asksToRunChain(said) { return nil }
        if TechnicianRequest.isShortAffirmative(said) {
            if proposed == name { return nil }
            if let previousReply, !TechnicianRequest.chainsMentioned(in: previousReply, among: [name]).isEmpty {
                return nil
            }
        }
        return notAskedRefusal
    }

    static let notAskedRefusal = "Not started — the technician didn't ask for a chain. Answer their question; "
        + "you may offer the chain by name."

    /// Why a chain was not started, and what can be shown instead. Pure.
    static func refusal(_ chain: ChainDefinition, unreadable: [UnreadableTable]) -> String {
        let missing = unreadable.filter { $0.source == nil }.map(\.label)
        let unread = unreadable.compactMap { table in table.source.map { "\(table.label) (\(TableLookup.spokenPage($0.table.page)) of \($0.documentName))" } }
        var parts: [String] = []
        if !missing.isEmpty { parts.append(missing.joined(separator: ", ") + ", which no loaded manual's tables include") }
        if !unread.isEmpty { parts.append(unread.joined(separator: ", ") + ", whose grid could not be read") }
        var text = "The chain '\(chain.name)' was not started: it needs " + parts.joined(separator: "; and ")
            + ". Nothing was started or recorded. Tell the technician which table it needs. "
        if !unread.isEmpty { text += "Offer to show that table's page, to work it from the book; open it with show_source only if they ask. " }
        if !missing.isEmpty { text += "For a table no loaded manual's tables include, offer to look for its page with manual_figure ('figure': its label)." }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The pages of the tables a refused chain needed, for "show me the table": a caption found
    /// over a grid that could not be read still names its page.
    private func noteUnreadable(_ unreadable: [UnreadableTable], session: FieldSessionService) {
        let citations = unreadable.compactMap(\.source).flatMap {
            TableLookup.citations(documentName: $0.documentName, label: $0.table.label, pages: [$0.table.page])
        }
        guard !citations.isEmpty else { return }
        session.sourceCenter.noteTableLookup(rows: [], citations: citations, sessionId: session.activeSession?.id)
    }

    private func answer(args: [String: Any], session: FieldSessionService) -> String {
        let value: String
        if let text = args["value"] as? String { value = text } else if let number = args["value"] as? NSNumber {
            value = number.stringValue
        } else { value = "" }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Pass 'value': what the technician said in reply to the chain's question."
        }
        do {
            let progress = try session.answerChain(value, tables: tables(session))
            note(progress, session: session)
            return present(progress)
        } catch {
            return error.localizedDescription
        }
    }

    private func status(_ session: FieldSessionService) -> String {
        guard let run = session.activeChain else { return "No rule chain is running." }
        let marked = run.origin.marking.map { " (\($0))" } ?? ""
        var lines = ["Running the chain '\(run.chain.name)'\(marked), step \(run.state.position + 1) of \(run.chain.steps.count)."]
        lines += run.state.entries.map { "- " + Self.entryLine($0) }
        if case .ask(let ask) = run.current { lines.append(Self.askLine(ask)) }
        return lines.joined(separator: "\n")
    }

    private func keep(_ session: FieldSessionService) -> String {
        switch session.keepLastProposedChain() {
        case .nothingToKeep:
            return "There is no proposed chain that ran to a result on this job to keep. A chain is kept after it "
                + "has run to its result with the technician, never before."
        case .failed(let reason):
            return reason
        case .kept(let kept, let review):
            var lines = ["Kept '\(kept.name)' on this phone, \(ChainOrigin.kept.marking ?? "unreviewed"). It is offered "
                         + "in the list on this phone only, and runs like any other chain. A chain your organisation "
                         + "adds to the vault's chains.md under the same name replaces it."]
            if let review { lines.append(review) }
            lines.append("To share the kept chains with the organisation, rule_chain 'share' puts them on the share "
                         + "sheet as a chains.md file to add to the vault by hand.")
            return lines.joined(separator: " ")
        }
    }

    /// The vault's kept chains on the share sheet as a `chains.md` fragment. Works with no office
    /// and no endpoint: a person picks where it goes.
    private func share(_ session: FieldSessionService) -> String {
        guard let store = session.activeVault,
              let share = RuleChainShare(vaultId: store.manifest.id, vaultName: store.manifest.name,
                                         kept: session.keptChains) else {
            return "No chain is kept on this phone for this vault, so there is nothing to share."
        }
        if let reason = DeliveryPolicy(settings: settings()).decide(channel: .shareSheet).reason {
            return reason
        }
        guard let lease = try? (injectedExports ?? .fieldSession).makeLease(data: Data(share.fragment.utf8), fileExtension: "md",
                                                 displayName: "chains", fallbackName: "chains") else {
            return "The chains file couldn't be prepared."
        }
        let attachment = DeliveryRequest.Attachment(url: lease.fileURL, kind: .chainsMarkdown,
                                                    filename: RuleChainShare.fileName)
        let request = DeliveryRequest.make(ruleChains: share, channel: .shareSheet, recipients: [],
                                           attachment: attachment)
        session.stageDelivery(request)
        return request.confirmation
    }

    // MARK: - Showing

    /// The chain's lookups so far are the answer's citations: "show me the table" opens their
    /// pages with the rows marked, as `table_lookup`'s do.
    private func note(_ progress: ChainProgress, session: FieldSessionService) {
        let citations = ChainRunner.citations(progress.state)
        guard !citations.isEmpty else { return }
        let founds = progress.state.values.values.compactMap(\.lookup).map(\.found)
        let rows = documentStore.map { TableLookupTool.rowPassages(for: founds, documentStore: $0) } ?? []
        // A table read from a picture has no row text to mark: its region is outlined (Plan JN P2).
        let areas = founds.flatMap(\.source.table.pictureAreas) + (progress.state.stop?.pictureAreas ?? [])
        session.sourceCenter.noteTableLookup(rows: rows, citations: citations, pictureAreas: areas,
                                             sessionId: session.activeSession?.id)
    }

    private func present(_ progress: ChainProgress) -> String {
        var lines = progress.newEntries.map { "- " + Self.entryLine($0) }
        if progress.newEntries.contains(where: { $0.pictureMark != nil }) {
            lines.append(Self.pictureLine)
        }
        switch progress.step {
        case .ask(let ask):
            lines.append(Self.askLine(ask))
        case .finished(let said):
            lines.append("Finished. Say the result: " + said.joined(separator: " "))
            if let marking = progress.origin.marking {
                lines.append("Say that this chain is \(marking): nobody has reviewed its steps.")
            }
            lines.append("Then read the steps back with their pages. Recorded on the job:")
            lines.append(progress.reading?.value ?? ChainRunner.readBack(progress.chain, state: progress.state))
            if progress.origin == .proposed {
                lines.append("If the technician wants it again, rule_chain 'keep' keeps it on this phone, unreviewed.")
            }
            lines += ChainRunner.sourceLines(progress.state)
        case .stopped(let stop):
            lines += Self.stoppedLines(progress.chain, stop: stop)
            lines += ChainRunner.sourceLines(progress.state)
        }
        return lines.joined(separator: "\n")
    }

    /// A stopped chain, said so that it is plainly over (Plan JW P0). The partner's trace: after a
    /// stop at a table step the model went on asking the technician for the chain's next value,
    /// and later started the chain again without saying so. Pure.
    static func stoppedLines(_ chain: ChainDefinition, stop: ChainStop) -> [String] {
        var table: String?
        if stop.stepIndex < chain.steps.count, case .lookup(let lookup) = chain.steps[stop.stepIndex].kind {
            table = ChainDefinition.label(lookup.table)
        }
        var lines = ["The chain '\(chain.name)' has ended and is not running. Stopped at step \(stop.stepIndex + 1): \(stop.reason)"]
        if let table { lines.append("It could not read \(table) at that step.") }
        lines.append("Tell the technician why. Do not ask the technician for any more values for this chain, and do "
                     + "not answer from memory or guess the value. "
                     + (stop.sourceLine == nil ? "" : "Offer to show the page; open it with show_source only if they ask. ")
                     + "What was worked so far is recorded on the job. To try again, the chain must be started "
                     + "again with rule_chain 'start', only when the technician asks.")
        return lines
    }

    /// Said whenever a step used a value read from a picture of a table (Plan JN P2).
    static let pictureLine = "A step marked \"from a picture\" used a value read from a picture of a table on the phone, "
        + "not from the PDF's text: say so when you read that step back, and offer to show the page so the "
        + "technician can check it (open it with show_source only if they ask)."

    private static func askLine(_ ask: ChainAsk) -> String {
        var line = ""
        if let again = ask.again { line += "That answer was not taken: \(again)\n" }
        line += "Next, ask the technician: \(ask.question) (it needs \(RuleChainWording.needs(ask))). "
            + "Call 'answer' with what they say."
        return line
    }

    private static func entryLine(_ entry: ChainState.Entry) -> String {
        entry.text + (entry.rules.isEmpty ? "" : " — follows \(entry.rules.joined(separator: ", "))")
    }
}
