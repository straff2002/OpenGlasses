import Foundation

/// A rule chain running on the open job (Plan JJ P2): the chain, where it is, and what it last
/// asked or said. A chain that finishes or stops writes its read-back on the job as a reading and
/// ends. Since P3 it is kept with the job record too (`PersistedChainRun`), so a relaunch resumes
/// it at the step it was on, and it knows where it came from: the vault, a proposal, or a chain
/// kept on this phone.
struct ActiveChainRun: Equatable {
    let sessionId: String
    let chain: ChainDefinition
    var state: ChainState
    var current: ChainStep
    var origin: ChainOrigin = .authored
    /// The passage each lookup of a proposed or kept chain came from, by the lookup's name.
    var sources: [String: String] = [:]
    /// Every answer given, in order, taken or not: replayed through the runner on a relaunch.
    var answers: [String] = []
    /// The turn the current question was put in (`TechnicianWords.currentTurn()`), when that turn
    /// had captured words (Plan KD P2): its answer has to come from a later turn. Not kept over a
    /// relaunch, where the turns count from the start again.
    var questionTurn: Int? = nil
}

/// A running chain as the job record keeps it (Plan JJ P3): the chain as `chains.md` writes it,
/// where it came from, and the answers given so far. The runner's state is not stored; replaying
/// the answers through `ChainRunner` against the same tables rebuilds it exactly, which is also
/// why no table cell is written into the job record before the chain files its read-back.
struct PersistedChainRun: Codable, Equatable {
    let chain: String
    let origin: ChainOrigin
    let sources: [String: String]
    let answers: [String]
}

/// A chain the model proposed on this job (Plan JJ P3), read back and waiting for the
/// technician's go; or, once one ran to a result, the chain "keep that chain" keeps.
struct PendingChainProposal: Equatable {
    let sessionId: String
    let proposal: ChainProposal
}

/// A chain the session can start: the vault's own, a kept one, or the proposal waiting for go.
struct OfferedChain: Equatable {
    let chain: ChainDefinition
    let origin: ChainOrigin
    let sources: [String: String]
}

/// What one start or answer came to, for the tool to say.
struct ChainProgress: Equatable {
    let chain: ChainDefinition
    let state: ChainState
    let step: ChainStep
    /// The read-back entries this call added (the steps it ran).
    let newEntries: [ChainState.Entry]
    /// The reading the read-back was filed as, when the chain finished or stopped.
    let reading: SpokenReading?
    var origin: ChainOrigin = .authored
}

extension FieldSessionService {

    enum ChainError: LocalizedError, Equatable {
        case noSession
        case alreadyRunning(String)
        case notRunning

        var errorDescription: String? {
            switch self {
            case .noSession: return "No active Field Assist session. Start a session before running a rule chain."
            case .alreadyRunning(let name):
                return "The chain '\(name)' is running. Answer its question, or stop it before starting another."
            case .notRunning: return "No rule chain is running. Use 'list' to see the chains, and 'start' to begin one."
            }
        }
    }

    /// The chain running on this job, if any. A chain started on an earlier job is not this job's.
    /// After a relaunch the chain the job record kept is rebuilt here, at the step it was on.
    var activeChain: ActiveChainRun? {
        if let run = chainRun, run.sessionId == activeSession?.id { return run }
        return resumePersistedChain()
    }

    /// The chains the session's vault's `chains.md` offers.
    var vaultChains: VaultChains {
        activeVault.map(VaultChains.init(store:)) ?? VaultChains()
    }

    /// The chains kept on this phone for the session's vault that are still offered: a chain the
    /// vault's `chains.md` now has under the same name supersedes the kept one.
    var keptChains: [KeptChain] {
        guard let store = activeVault else { return [] }
        return KeptChains.offered(KeptChains.read(store: store), authored: vaultChains.chains)
    }

    /// Every chain the session can start: the vault's, then those kept on this phone, then the
    /// proposal waiting for the technician's go.
    var offeredChains: [OfferedChain] {
        var out = vaultChains.chains.map { OfferedChain(chain: $0, origin: .authored, sources: [:]) }
        out += keptChains.compactMap { kept in
            kept.chain.map { OfferedChain(chain: $0, origin: .kept, sources: kept.sources) }
        }
        if let pending = pendingProposal {
            out.append(OfferedChain(chain: pending.proposal.chain, origin: .proposed, sources: pending.proposal.sources))
        }
        return out
    }

    /// The proposal waiting for go on this job, if any.
    var pendingProposal: PendingChainProposal? {
        guard let pending = chainProposal, pending.sessionId == activeSession?.id else { return nil }
        return pending
    }

    /// The vault's tables, from its manuals still in the vault, as a chain's lookups read them.
    func chainTables(documentStore store: DocumentStore? = nil) -> [TableLookup.Source] {
        guard let vault = activeVault, let documentStore = store ?? documentStore else { return [] }
        return TableLookupTool.sources(store: vault, session: self, documentStore: documentStore,
                                       namedDocument: false, said: "")
    }

    /// Start a chain and run it to its first question (or its end).
    /// `turn` is the turn it starts in, which its first question is put in.
    func startChain(_ chain: ChainDefinition, tables: [TableLookup.Source], origin: ChainOrigin = .authored,
                    sources: [String: String] = [:], turn: Int? = nil) throws -> ChainProgress {
        guard let session = activeSession else { throw ChainError.noSession }
        if let running = activeChain { throw ChainError.alreadyRunning(running.chain.name) }
        var state = ChainState()
        let step = ChainRunner.advance(chain, state: &state, answer: nil, tables: tables)
        let run = ActiveChainRun(sessionId: session.id, chain: chain, state: state, current: step,
                                 origin: origin, sources: sources, questionTurn: turn)
        // A proposal that starts is the running chain now, not one waiting for go.
        if origin == .proposed { chainProposal = nil }
        chainRun = run
        return settle(run, newEntries: state.entries)
    }

    /// The technician's answer to the chain's current question, given in `turn`. The question it
    /// puts next — or the same one again, when the answer was not taken — is put in that turn.
    func answerChain(_ answer: String, tables: [TableLookup.Source], turn: Int? = nil) throws -> ChainProgress {
        guard var run = activeChain else { throw ChainError.notRunning }
        let before = run.state.entries.count
        run.answers.append(answer)
        run.current = ChainRunner.advance(run.chain, state: &run.state, answer: answer, tables: tables)
        run.questionTurn = turn
        chainRun = run
        return settle(run, newEntries: Array(run.state.entries.dropFirst(before)))
    }

    /// Stop the running chain without a result. Nothing is recorded: the technician stopped it.
    @discardableResult
    func stopChain() -> ActiveChainRun? {
        let run = activeChain
        chainRun = nil
        persistChainRun(nil)
        return run
    }

    /// A chain that finished or stopped files its read-back on the job and ends; one still asking
    /// carries on, kept with the job record so a relaunch resumes it here.
    private func settle(_ run: ActiveChainRun, newEntries: [ChainState.Entry]) -> ChainProgress {
        var reading: SpokenReading?
        switch run.current {
        case .ask:
            persistChainRun(PersistedChainRun(chain: KeptChains.markdown(run.chain), origin: run.origin,
                                              sources: run.sources, answers: run.answers))
        case .finished, .stopped:
            let name = run.chain.name + (run.origin.marking.map { " (\($0))" } ?? "")
            reading = recordChainReading(chain: name, readBack: Self.markedReadBack(run),
                                         pictureMarks: ChainRunner.pictureMarks(run.state))
            chainRun = nil
            persistChainRun(nil)
            // A proposed chain that ran to a result is what "keep that chain" keeps; one that
            // stopped is not kept.
            if run.origin == .proposed, case .finished = run.current, let sessionId = activeSession?.id {
                let proposal = ChainProposal(chain: run.chain, sources: run.sources, missingTables: [])
                lastProposedResult = PendingChainProposal(sessionId: sessionId, proposal: proposal)
            }
        }
        return ChainProgress(chain: run.chain, state: run.state, step: run.current, newEntries: newEntries,
                             reading: reading, origin: run.origin)
    }

    /// The read-back as filed: an authored chain's exactly as the runner writes it; a proposed or
    /// kept one marked unreviewed in its first line, with the passages its lookups came from.
    static func markedReadBack(_ run: ActiveChainRun) -> String {
        let readBack = ChainRunner.readBack(run.chain, state: run.state)
        guard let marking = run.origin.marking else { return readBack }
        var lines = readBack.components(separatedBy: "\n")
        if !lines.isEmpty { lines[0] += " (\(marking))" }
        let passages = ChainProposal.lookupNames(run.chain).compactMap { name in
            run.sources[name].map { "\(name) from \($0)" }
        }
        if !passages.isEmpty { lines.insert("Proposed from the passages retrieved: " + passages.joined(separator: "; "), at: 1) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Relaunch

    /// The chain the job record kept, rebuilt by replaying its answers through the runner against
    /// the vault's tables. Nil when there is none, when the tables cannot be read yet, or when the
    /// replay no longer ends on a question (the tables changed): nothing is filed either way.
    private func resumePersistedChain() -> ActiveChainRun? {
        guard let session = activeSession, let record = session.ruleChainRun, documentStore != nil,
              let chain = ChainParser.parse(record.chain).chains.first else { return nil }
        let tables = chainTables()
        var state = ChainState()
        var step = ChainRunner.advance(chain, state: &state, answer: nil, tables: tables)
        for answer in record.answers {
            step = ChainRunner.advance(chain, state: &state, answer: answer, tables: tables)
        }
        guard case .ask = step else { return nil }
        let run = ActiveChainRun(sessionId: session.id, chain: chain, state: state, current: step,
                                 origin: record.origin, sources: record.sources, answers: record.answers)
        chainRun = run
        return run
    }

    // MARK: - Proposals (Plan JJ P3)

    /// What a proposal is checked against on this job: the passages retrieved, the labels of the
    /// tables the vault's manuals print, and the names already offered.
    func proposalContext(documentStore store: DocumentStore? = nil) -> ChainProposal.Context {
        let retrieved = sourceCenter.memory.sessionId == activeSession?.id ? sourceCenter.memory.retrieved : []
        let taken = vaultChains.chains.map(\.name) + keptChains.map(\.name)
        return ChainProposal.Context(passages: retrieved.map(ChainProposal.Passage.init),
                                     tableLabels: chainTables(documentStore: store).map(\.table.label),
                                     takenNames: taken)
    }

    /// Hold a checked proposal for the technician's go.
    func holdProposal(_ proposal: ChainProposal) throws {
        guard let session = activeSession else { throw ChainError.noSession }
        chainProposal = PendingChainProposal(sessionId: session.id, proposal: proposal)
    }

    /// Withdraw the proposal waiting for go. Nothing was run or filed.
    @discardableResult
    func withdrawProposal() -> ChainProposal? {
        let pending = pendingProposal
        chainProposal = nil
        return pending?.proposal
    }

    // MARK: - Keeping (Plan JJ P3)

    enum KeepOutcome: Equatable {
        /// Kept on the phone. `review` says what became of the copy for the office's review: nil
        /// when the organisation has no office here, else the sentence to say.
        case kept(KeptChain, review: String?)
        case nothingToKeep
        case failed(String)
    }

    /// Keep the last proposed chain that ran to a result on this job, on this phone, beside the
    /// vault's own chains. With the organisation's office as this phone's destination, the same
    /// fragment is also filed for its review through the team-learning bundle; without one,
    /// keeping is the whole of it and nothing is queued.
    func keepLastProposedChain(now: Date = Date()) -> KeepOutcome {
        guard let session = activeSession, let store = activeVault,
              let result = lastProposedResult, result.sessionId == session.id else { return .nothingToKeep }
        let kept = KeptChain(chain: result.proposal.chain, sources: result.proposal.sources, keptAt: now,
                             jobReference: session.jobReference)
        do {
            try KeptChains.write(KeptChains.keeping(kept, in: KeptChains.read(store: store)), store: store)
        } catch {
            return .failed("The chain couldn't be saved on this phone.")
        }
        guard chainOfficeConfigured() else { return .kept(kept, review: nil) }
        let service = chainReviewCandidates ?? .shared
        switch service.noteRuleChain(fragment: KeptChains.fragment([kept])) {
        case .success:
            return .kept(kept, review: "A copy is filed for your office's review and goes with the next team-learning bundle.")
        case .failure(let refusal):
            return .kept(kept, review: "It couldn't be filed for the office's review: \(refusal.spoken) It is still kept on this phone, and can be shared.")
        }
    }

    // MARK: - Prompt

    /// The running chain's current question — the model asks it in its own words and the runner
    /// keeps the values — or, with none running, the chains the session offers by what they
    /// answer, a proposal waiting for go, and how to propose one.
    func chainPromptContext() -> String? {
        if let run = activeChain, case .ask(let ask) = run.current {
            return Self.chainPromptBlock(chain: run.chain, state: run.state, ask: ask, origin: run.origin)
        }
        var blocks: [String] = []
        let offered = vaultChains.chains.map { ($0, ChainOrigin.authored) }
            + keptChains.compactMap { kept in kept.chain.map { ($0, ChainOrigin.kept) } }
        if !offered.isEmpty {
            var lines = ["RULE CHAINS this vault offers. When the technician's question is one a chain answers, offer it "
                         + "by name; start it (rule_chain 'start', its name) only when they ask for it or say yes to "
                         + "your offer. Never work its steps yourself:"]
            lines += offered.prefix(8).map { chain, origin in
                "- \(chain.name)" + (origin.marking.map { " (\($0))" } ?? "")
                    + (chain.answers.isEmpty ? "" : ": \(chain.answers)")
            }
            if offered.count > 8 { lines.append("- and \(offered.count - 8) more (rule_chain 'list')") }
            blocks.append(lines.joined(separator: "\n"))
        }
        if let pending = pendingProposal {
            blocks.append(Self.proposalPromptBlock(pending.proposal))
        }
        if !offered.isEmpty || vaultHasTables {
            blocks.append(Self.proposingRule)
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// Whether a manual in the vault has table rows: where a chain could be proposed at all.
    private var vaultHasTables: Bool {
        guard let store = activeVault, let documentStore else { return false }
        let ids = documentStore.list(namespace: DocumentStore.vaultNamespace(store.manifest.id)).map(\.id)
        return !ids.isEmpty && documentStore.hasTableRows(documentIds: ids)
    }

    /// How a chain is proposed: from retrieved passages, never from memory, and never run without
    /// the technician's go.
    static let proposingRule = """
        PROPOSING A CHAIN: when the technician's question is about a table or a rule and no chain above answers it, \
        first retrieve the clauses with manual_lookup (and the cells with table_lookup), then call propose_chain with \
        the steps those passages say, in the chain syntax: a 'cite' line naming the rule on every lookup and check, \
        and the Source line of the passage each lookup came from. Never write a step, rule, table or value from \
        memory of any code. Read the proposal back as propose_chain returns it, and start it with rule_chain only \
        when the technician says go.
        """

    static func proposalPromptBlock(_ proposal: ChainProposal) -> String {
        """
        PROPOSED RULE CHAIN — \(proposal.chain.name) (\(ChainOrigin.proposed.marking ?? "")), read back and waiting \
        for the technician. On go, call rule_chain 'start' with chain '\(proposal.chain.name)'. To change a step \
        ("ask me the ambient instead"), call propose_chain action 'change' with its number and the new step. On \
        stop, call propose_chain action 'withdraw'. Never run it, or any step of it, without their go.
        """
    }

    /// The block is as of the turn's start; a rule_chain result says what is running now.
    static let supersededLine = "This block was written at the start of the turn. A rule_chain result says which "
        + "chain is running now and which step it is waiting for; where they differ, the result is right."

    static func chainPromptBlock(chain: ChainDefinition, state: ChainState, ask: ChainAsk,
                                 origin: ChainOrigin = .authored) -> String {
        let marked = origin.marking.map { " (\($0))" } ?? ""
        var lines = ["ACTIVE RULE CHAIN — \(chain.name)\(marked) (step \(ask.stepIndex + 1) of \(chain.steps.count)):"]
        lines.append("Ask the technician, in your own words: \(ask.question)")
        lines.append("It needs " + RuleChainWording.needs(ask) + ".")
        if let again = ask.again {
            lines.append("Their last answer was not taken: \(again)")
        }
        lines.append("Ask it and stop: their answer comes in their next turn. Then call rule_chain action 'answer' "
                     + "with step \"\(ask.name)\" and only what they said in that turn. Never answer for them, take a "
                     + "value from earlier in the conversation, assume a value, or work a step yourself: the chain "
                     + "does the lookups and the arithmetic, and reads every step back with its page.")
        let done = state.entries.map(\.text)
        if !done.isEmpty {
            lines.append("So far: " + done.joined(separator: "; "))
        }
        // Built once per turn (Plan KD P2): after a switch mid-turn this block is out of date, and
        // every rule_chain result opens with what is running now.
        lines.append(supersededLine)
        return lines.joined(separator: "\n")
    }
}

/// How a chain's question and progress are said, shared by the prompt block and the tool.
enum RuleChainWording {

    /// "a number in A, from 1 to 400", "a number", "the technician's words".
    static func needs(_ ask: ChainAsk) -> String {
        if ask.isText { return "the technician's words, as they say them" }
        var text = "a number" + (ask.unit.map { " in \($0)" } ?? "")
        if let range = ask.range {
            text += ", from \(ChainRunner.display(range.lowerBound)) to \(ChainRunner.display(range.upperBound))"
        }
        return text
    }
}
