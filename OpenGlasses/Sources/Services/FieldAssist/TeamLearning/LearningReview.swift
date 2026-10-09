import Foundation

/// The review of team learnings as a pure state machine (Plan FP §2):
///
///     candidate → approved | editedAndApproved | rejected(reason) | merged(into:)
///     approved, editedAndApproved → superseded(by:) | retracted(reason:)
///
/// `rejected`, `merged`, `superseded` and `retracted` are final. Re-applying the transition that
/// reached a final state (the same supersession, a second retraction) returns that state
/// unchanged, so a replayed decision is idempotent; anything else is refused with the reason.
///
/// Everything here is a function of its inputs — the candidate, the entries, the approver, the
/// device's role, the licence's answer, the safety core — so every transition and every refusal
/// is a test. `LearningReviewService` is the thin layer that reads those inputs off the phone and
/// writes the results to the stores and the corpus.
enum LearningReview {

    // MARK: - States and actions

    enum State: Equatable {
        case candidate
        case approved(entryID: String)
        case editedAndApproved(entryID: String)
        case rejected(reason: String)
        case merged(into: String)
        case superseded(by: String)
        case retracted(reason: String)

        /// An approved entry that still answers.
        var isApproved: Bool {
            switch self {
            case .approved, .editedAndApproved: return true
            default: return false
            }
        }
    }

    enum Action: Equatable {
        case approve(entryID: String)
        case editAndApprove(entryID: String)
        case reject(reason: String)
        case merge(into: String)
        case supersede(by: String)
        case retract(reason: String)
    }

    /// Why a review action did nothing, in the words the reviewer reads.
    enum Refusal: Error, Equatable {
        case invalidTransition(from: State, action: Action)
        case notEntitled(String)
        case hipaa
        case authorIsApprover
        case missingApprover
        case missingRole
        case roleTooLong(count: Int)
        case missingReason
        case reasonTooLong(count: Int)
        case text(LearningCandidateText.Refusal)
        case candidateWithdrawn
        case subjectNeeded
        case safetyConfirmationNeeded(LearningSafetyCheck.Finding)
        case unknownCandidate(String)
        case unknownEntry(String)
        case entryNotLive(String)

        var spoken: String {
            switch self {
            case .invalidTransition(let from, let action):
                return "That can't be done: a learning that is \(LearningReview.describe(from)) can't be "
                    + "\(LearningReview.describe(action))."
            case .notEntitled(let reason): return reason
            case .hipaa:
                return "Team learnings are unavailable while HIPAA mode is on: nothing can be reviewed or published."
            case .authorIsApprover:
                return "Not approved: the person approving is the one who filed it. Ask a reviewer to approve it, "
                    + "or mark this device as a reviewer device."
            case .missingApprover: return "Not done: the reviewer's name is needed."
            case .missingRole: return "Not approved: the reviewer's role is needed — it is what the citation names."
            case .roleTooLong(let count):
                return "Not approved: the role is \(count) characters and can be at most \(LearningEntry.roleLimit)."
            case .missingReason: return "Not done: say why, in a few words, for the record."
            case .reasonTooLong(let count):
                return "Not done: the reason is \(count) characters and can be at most \(LearningCandidateText.fieldLimit)."
            case .text(let refusal): return refusal.spoken.replacingOccurrences(of: "Nothing was filed", with: "Not approved")
            case .candidateWithdrawn: return "Not reviewed: its author withdrew it."
            case .subjectNeeded:
                return "Not approved: no machine was resolved when it was filed. Name the model it is about, or the practice."
            case .safetyConfirmationNeeded(let finding):
                return "This finding touches the vault's safety notes (\(finding.terms.joined(separator: ", "))). "
                    + "Confirm a second time to publish it; it will be marked as departing from a safety note."
            case .unknownCandidate(let id): return "There's no candidate \(id) on this device."
            case .unknownEntry(let id): return "There's no team learning \(id) on this device."
            case .entryNotLive(let id): return "Team learning \(id) has been superseded or retracted."
            }
        }
    }

    /// The transition function. Pure: what state an action leads to, or why it cannot.
    static func next(_ state: State, _ action: Action) -> Result<State, Refusal> {
        switch (state, action) {
        case (.candidate, .approve(let id)): return .success(.approved(entryID: id))
        case (.candidate, .editAndApprove(let id)): return .success(.editedAndApproved(entryID: id))
        case (.candidate, .reject(let reason)):
            return reasonProblem(reason).map(Result.failure) ?? .success(.rejected(reason: trimmed(reason)))
        case (.candidate, .merge(let id)): return .success(.merged(into: id))
        case (.approved, .supersede(let id)), (.editedAndApproved, .supersede(let id)):
            return .success(.superseded(by: id))
        case (.approved, .retract(let reason)), (.editedAndApproved, .retract(let reason)):
            return reasonProblem(reason).map(Result.failure) ?? .success(.retracted(reason: trimmed(reason)))
        // Replays: the decision that made a final state, made again, changes nothing.
        case (.superseded(let by), .supersede(let again)) where by == again: return .success(state)
        case (.retracted, .retract): return .success(state)
        default: return .failure(.invalidTransition(from: state, action: action))
        }
    }

    /// The state an entry is in, from its stamps.
    static func state(of entry: LearningEntry) -> State {
        if entry.retractedAt != nil { return .retracted(reason: entry.retractionReason ?? "") }
        if let by = entry.supersededBy { return .superseded(by: by) }
        return entry.captured == nil ? .approved(entryID: entry.id) : .editedAndApproved(entryID: entry.id)
    }

    /// The state a candidate is in, from its status.
    static func state(of candidate: LearningCandidate) -> State {
        switch candidate.status {
        case .filed, .sent, .received, .withdrawn: return .candidate
        case .approved: return .approved(entryID: candidate.entryID ?? "")
        case .merged: return .merged(into: candidate.entryID ?? "")
        case .notTakenUp: return .rejected(reason: candidate.reviewReason ?? "")
        }
    }

    // MARK: - Who is reviewing

    /// The reviewer, as the record names them: a display name for the history and a role for the
    /// citation ("approved by Service manager").
    struct Approver: Equatable {
        let name: String
        let role: String

        init(name: String, role: String) {
            self.name = name
            self.role = role
        }
    }

    /// What the phone says about the review it is being asked for.
    struct Context: Equatable {
        /// `Config.teamLearningReviewerDevice`: a device the organisation marked as a reviewer's.
        var isReviewerDevice: Bool
        /// The licence's refusal for `.teamLearnings`, or nil when granted.
        var entitlementRefusal: String?
        /// `Config.hipaaMode`: review and publish are refused outright.
        var hipaa: Bool

        init(isReviewerDevice: Bool, entitlementRefusal: String? = nil, hipaa: Bool = false) {
            self.isReviewerDevice = isReviewerDevice
            self.entitlementRefusal = entitlementRefusal
            self.hipaa = hipaa
        }
    }

    /// Fields the reviewer changed. Nil means "as written"; a field equal to the captured text is
    /// no edit.
    struct Edits: Equatable {
        var finding: String?
        var symptom: String?
        var fix: String?

        init(finding: String? = nil, symptom: String? = nil, fix: String? = nil) {
            self.finding = finding
            self.symptom = symptom
            self.fix = fix
        }
    }

    /// An approval's result: the entry it produced, the candidate's new state, and what the safety
    /// check found.
    struct Approval: Equatable {
        let entry: LearningEntry
        let state: State
        let safety: LearningSafetyCheck.Finding
    }

    // MARK: - Approve

    /// Approve a candidate, as written or edited, into an entry.
    ///
    /// - Parameters:
    ///   - subject: what the entry is about; defaults to the candidate's resolved model, then the
    ///     model as spoken. A candidate with neither needs one named.
    ///   - vaultIDs: the vaults whose answers may use it; defaults to the vault it was filed in.
    ///     Empty means every vault.
    ///   - safetyCore: the core files of the vaults it is approved for — whose `safety` files the
    ///     check reads.
    ///   - confirmsSafetyDeparture: the second confirmation a safety collision needs.
    static func approve(_ candidate: LearningCandidate, approver: Approver, edits: Edits? = nil,
                        subject: LearningEntry.Subject? = nil, vaultIDs: [String]? = nil,
                        supersedes: String? = nil,
                        safetyCore: [(filename: String, contents: String)] = [],
                        confirmsSafetyDeparture: Bool = false,
                        context: Context, now: Date,
                        entryID: String = LearningCandidate.newID()) -> Result<Approval, Refusal> {
        if let refusal = gate(context) { return .failure(refusal) }
        guard !candidate.withdrawn else { return .failure(.candidateWithdrawn) }
        let person: (name: String, role: String)
        switch checkApprover(approver) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): person = value
        }
        let authorIsApprover = isSamePerson(candidate.author, person.name)
        if authorIsApprover && !context.isReviewerDevice { return .failure(.authorIsApprover) }

        // The text as approved, and whether it differs from the text as captured.
        let captured = LearningEntry.Texts(finding: candidate.finding, symptom: candidate.symptom, fix: candidate.fix)
        let cleaned: LearningCandidateText.Cleaned
        switch LearningCandidateText.clean(finding: edits?.finding ?? candidate.finding,
                                           symptom: edits?.symptom ?? candidate.symptom,
                                           fix: edits?.fix ?? candidate.fix) {
        case .failure(let refusal): return .failure(.text(refusal))
        case .success(let value): cleaned = value
        }
        let edited = cleaned.finding != captured.finding || cleaned.symptom != captured.symptom
            || cleaned.fix != captured.fix
        let action: Action = edited ? .editAndApprove(entryID: entryID) : .approve(entryID: entryID)
        let state: State
        switch next(Self.state(of: candidate), action) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): state = value
        }

        guard let resolvedSubject = subject.flatMap(cleanSubject) ?? defaultSubject(of: candidate) else {
            return .failure(.subjectNeeded)
        }

        let safety = LearningSafetyCheck.check(finding: cleaned.finding, symptom: cleaned.symptom,
                                               fix: cleaned.fix, coreFiles: safetyCore)
        if safety.collides && !confirmsSafetyDeparture { return .failure(.safetyConfirmationNeeded(safety)) }

        let entry = LearningEntry(
            id: entryID, subject: resolvedSubject, vaultIDs: vaultIDs ?? [candidate.vaultId],
            finding: cleaned.finding, symptom: cleaned.symptom, fix: cleaned.fix,
            approvedAt: wholeSecond(now), approvedByRole: person.role, approvedByName: person.name,
            authorIsApprover: authorIsApprover, contradictsSafetyNote: safety.collides,
            supersedes: supersedes, candidateID: candidate.id, origin: candidate.origin,
            sourceJobIDs: [candidate.sessionId], confirmedJobCount: 1,
            captured: edited ? captured : nil)
        return .success(Approval(entry: entry, state: state, safety: safety))
    }

    // MARK: - Merge (decision 3 of 2026-10-09)

    /// Fold a candidate that says what an approved entry already says into that entry: its job
    /// joins `sourceJobIDs` and `confirmedJobCount` rises — no second entry, and the citation does
    /// not change. A candidate from a job the entry already counts adds nothing to the count.
    static func merge(_ candidate: LearningCandidate, into entry: LearningEntry, approver: Approver,
                      context: Context) -> Result<(entry: LearningEntry, state: State), Refusal> {
        if let refusal = gate(context) { return .failure(refusal) }
        guard !candidate.withdrawn else { return .failure(.candidateWithdrawn) }
        guard entry.isLive else { return .failure(.entryNotLive(entry.id)) }
        let person: (name: String, role: String)
        switch checkApprover(approver) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): person = value
        }
        if isSamePerson(candidate.author, person.name) && !context.isReviewerDevice {
            return .failure(.authorIsApprover)
        }
        let state: State
        switch next(Self.state(of: candidate), .merge(into: entry.id)) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let value): state = value
        }
        var merged = entry
        var jobs = entry.sourceJobIDs ?? []
        let count = entry.confirmedJobCount ?? max(1, jobs.count)
        if !jobs.contains(candidate.sessionId) {
            jobs.append(candidate.sessionId)
            merged.confirmedJobCount = count + 1
        } else {
            merged.confirmedJobCount = count
        }
        merged.sourceJobIDs = jobs
        return .success((merged, state))
    }

    /// Entries a candidate probably repeats: live, the same subject by identity, and the same
    /// finding once case and spacing are set aside. A suggestion for the review surface — whether
    /// two findings "say the same" is the reviewer's call.
    static func mergeSuggestions(for candidate: LearningCandidate, among entries: [LearningEntry]) -> [String] {
        guard !candidate.withdrawn, let subject = defaultSubject(of: candidate) else { return [] }
        let finding = normalisedFinding(candidate.finding)
        guard !finding.isEmpty else { return [] }
        return entries.filter { entry in
            entry.isLive && sameSubject(entry.subject, subject) && normalisedFinding(entry.finding) == finding
        }.map(\.id)
    }

    /// Case-folded, whitespace collapsed.
    static func normalisedFinding(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func sameSubject(_ a: LearningEntry.Subject, _ b: LearningEntry.Subject) -> Bool {
        switch (a, b) {
        case (.model(let x, _, _), .model(let y, _, _)):
            return VaultRetriever.ModelScope.identity(x) == VaultRetriever.ModelScope.identity(y)
        case (.practice(let x), .practice(let y)):
            return normalisedFinding(x) == normalisedFinding(y)
        default:
            return false
        }
    }

    // MARK: - Reject

    /// Not taken up, with the reviewer's reason for the author.
    static func reject(_ candidate: LearningCandidate, reason: String, context: Context) -> Result<State, Refusal> {
        if let refusal = gate(context) { return .failure(refusal) }
        guard !candidate.withdrawn else { return .failure(.candidateWithdrawn) }
        return next(Self.state(of: candidate), .reject(reason: reason))
    }

    // MARK: - Supersede and retract

    /// Stamp `old` as replaced by `replacement`. Not gated: removing an answer from service is
    /// always allowed — the replacement's own approval is where the gate sits.
    static func supersede(_ old: LearningEntry, by replacement: LearningEntry, now: Date) -> Result<LearningEntry, Refusal> {
        guard replacement.id != old.id, replacement.isLive else {
            return .failure(.invalidTransition(from: state(of: old), action: .supersede(by: replacement.id)))
        }
        switch next(state(of: old), .supersede(by: replacement.id)) {
        case .failure(let refusal): return .failure(refusal)
        case .success: break
        }
        var stamped = old
        if stamped.supersededAt == nil { stamped.supersededAt = wholeSecond(now) }
        stamped.supersededBy = replacement.id
        return .success(stamped)
    }

    /// Take an entry out of service, keeping it as history with the reason. Not gated, for the same
    /// reason as supersession; a second retraction keeps the first one's stamp.
    static func retract(_ entry: LearningEntry, reason: String, now: Date) -> Result<LearningEntry, Refusal> {
        switch next(state(of: entry), .retract(reason: reason)) {
        case .failure(let refusal): return .failure(refusal)
        case .success: break
        }
        guard entry.retractedAt == nil else { return .success(entry) }
        var stamped = entry
        stamped.retractedAt = wholeSecond(now)
        stamped.retractionReason = trimmed(reason)
        return .success(stamped)
    }

    // MARK: - Parts

    /// HIPAA first, then the licence.
    static func gate(_ context: Context) -> Refusal? {
        if context.hipaa { return .hipaa }
        if let reason = context.entitlementRefusal { return .notEntitled(reason) }
        return nil
    }

    /// The same person, by display name: trimmed, case- and width-folded, inner spacing collapsed.
    static func isSamePerson(_ a: String, _ b: String) -> Bool {
        let left = normalisedFinding(a), right = normalisedFinding(b)
        return !left.isEmpty && left == right
    }

    /// The subject a candidate implies: its resolved model, else the model as spoken.
    static func defaultSubject(of candidate: LearningCandidate) -> LearningEntry.Subject? {
        if let token = candidate.modelToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return .model(modelToken: token)
        }
        if let spoken = candidate.spokenModel?.trimmingCharacters(in: .whitespacesAndNewlines), !spoken.isEmpty {
            return .model(modelToken: spoken)
        }
        return nil
    }

    /// A subject the reviewer named, made plain; nil when it cleans to nothing.
    static func cleanSubject(_ subject: LearningEntry.Subject) -> LearningEntry.Subject? {
        func plain(_ raw: String?) -> String? {
            guard let raw, case .success(let value) = LearningCandidateText.normalise(raw, field: .symptom),
                  !value.isEmpty else { return nil }
            return String(String.UnicodeScalarView(value.unicodeScalars.prefix(LearningCandidateText.authorLimit)))
        }
        switch subject {
        case .model(let token, let manufacturer, let type):
            return plain(token).map { .model(modelToken: $0, manufacturer: plain(manufacturer), equipmentType: plain(type)) }
        case .practice(let topic):
            return plain(topic).map { .practice(topic: $0) }
        }
    }

    private static func checkApprover(_ approver: Approver) -> Result<(name: String, role: String), Refusal> {
        let name = approver.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.missingApprover) }
        guard case .success(let role) = LearningCandidateText.normalise(approver.role, field: .symptom), !role.isEmpty else {
            return .failure(.missingRole)
        }
        let count = LearningCandidateText.length(role)
        guard count <= LearningEntry.roleLimit else { return .failure(.roleTooLong(count: count)) }
        return .success((LearningCandidateText.author(name), role))
    }

    private static func reasonProblem(_ reason: String) -> Refusal? {
        let text = trimmed(reason)
        if text.isEmpty { return .missingReason }
        let count = LearningCandidateText.length(text)
        return count > LearningCandidateText.fieldLimit ? .reasonTooLong(count: count) : nil
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The contract carries Unix seconds.
    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func describe(_ state: State) -> String {
        switch state {
        case .candidate: return "awaiting review"
        case .approved, .editedAndApproved: return "approved"
        case .rejected: return "not taken up"
        case .merged: return "merged into another"
        case .superseded: return "superseded"
        case .retracted: return "retracted"
        }
    }

    static func describe(_ action: Action) -> String {
        switch action {
        case .approve, .editAndApprove: return "approved"
        case .reject: return "turned down"
        case .merge: return "merged"
        case .supersede: return "superseded"
        case .retract: return "retracted"
        }
    }
}
