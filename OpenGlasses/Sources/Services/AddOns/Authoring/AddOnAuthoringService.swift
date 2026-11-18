import Foundation

/// The authoring model: one stateless request, two strings in, text out. A seam so the session is
/// tested with a scripted fake.
protocol AddOnAuthoringModel {
    @MainActor func complete(system: String, user: String) async throws -> String
}

/// The question asked before every test run of a drafted add-on. The domains are exactly the
/// minimised `network` set: the hosts the test may reach and nothing else.
struct AddOnTestConsentRequest: Equatable, Sendable {
    let sessionID: String
    let addOnName: String
    let domains: [String]

    /// "To test it, I'll contact api.example.org once with a sample question. OK?"
    var line: String {
        let list = domains.formatted(.list(type: .and))
        return String(localized: "To test it, I'll contact \(list) once with a sample question. OK?")
    }
}

/// Builds an add-on the wearer asked for ("build yourself a skill for that"): preflight, research,
/// draft, validate and minimise, ask before testing, test once, assess, and offer the result on
/// the normal add-on sheet with a Tested panel. Nothing is installed unless the wearer approves it
/// there; anything turned down, failed or left for a day is deleted with its test trace.
///
/// The state and its caps are `AddOnAuthoringSession` (pure); this type does the I/O around it and
/// checks after every await that the session it is running is still the live one, so a cancel or
/// an expired clock stops it between steps.
@MainActor
final class AddOnAuthoringService: ObservableObject {

    struct Dependencies {
        var model: any AddOnAuthoringModel
        /// A web search, already framed by whoever runs it; the result is shown to the model as data.
        var search: @MainActor (String) async -> String
        var docs: any AddOnDocsFetcher
        /// The network edge the test run uses (`BoundedAddOnHTTPTransport` in the app).
        var transport: any AddOnHTTPTransport
        var clock: any AddOnClock = SystemAddOnClock()
        /// Ask the wearer before a test, on the phone and by voice. Only a yes tests.
        /// Only `.approved` tests; `.busy` means the wearer was not asked.
        var consent: @MainActor (AddOnTestConsentRequest) async -> ConfirmationOutcome
        /// Say a short progress line, sparingly.
        var announce: @MainActor (String) async -> Void = { _ in }
        var conditions: @MainActor () -> AddOnAuthoringAvailability.Conditions
        var nativeCapabilities: @MainActor () -> [AddOnAuthoringPreflight.Capability] = { [] }
        /// The app's own tool names, for the definition screen.
        var nativeToolNames: @MainActor () -> Set<String> = { [] }
        /// What the wearer has told the assistant, so a sample value never carries it.
        var wearerFacts: @MainActor () -> [String] = { [] }
        var runContext: @MainActor (RecipeAddOnManifest.Permissions) -> RecipeRunContext
        var matcher: AddOnAuthoringPreflight.Matcher = AddOnAuthoringPreflight.lexicalMatch
    }

    enum StartOutcome: Equatable {
        case started(String)
        case refused(String)

        var text: String {
            switch self {
            case .started(let text), .refused(let text): return text
            }
        }
    }

    @Published private(set) var session: AddOnAuthoringSession?
    /// What the last session ended with, for `status`.
    @Published private(set) var lastMessage: String?
    let drafts: AddOnDraftStore

    private let store: AddOnStore
    private let install: AddOnInstallService
    private let deps: Dependencies
    private var task: Task<Void, Never>?
    private var log: [AddOnAuthoringPrompt.LogEntry] = []
    private var fetched: [URL] = []

    static let maxGoalLength = AddOnAuthoringPreflight.maxGoalLength
    static let maxOutputTokens = 4_096

    init(store: AddOnStore, drafts: AddOnDraftStore, install: AddOnInstallService, dependencies: Dependencies) {
        self.store = store
        self.drafts = drafts
        self.install = install
        self.deps = dependencies
        install.onSelfBuiltResolved = { [weak self] sessionID, installed in
            self?.resolve(sessionID: sessionID, installed: installed)
        }
        drafts.sweepExpired(now: dependencies.clock.now())
    }

    // MARK: - Starting

    /// Build a new add-on for `goal`, in the wearer's words.
    func start(goal raw: String) -> StartOutcome {
        begin(goal: Self.cleaned(raw), mode: .create, currentSource: nil)
    }

    /// Build a new version of an add-on the assistant built, named roughly as the wearer said it.
    func improve(addOnNamed name: String, goal raw: String) -> StartOutcome {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = store.installed.filter(\.isBuiltByAssistant)
        let match = candidates.first { $0.name.lowercased() == wanted }
            ?? candidates.first { !wanted.isEmpty && ($0.name.lowercased().contains(wanted) || wanted.contains($0.name.lowercased())) }
        guard let record = match, case .success(let loaded) = store.loaded(id: record.id),
              let source = store.sourceText(id: record.id) else {
            return .refused(String(localized: "I can only improve add-ons I built. You can edit any add-on's source in Settings, under Add-ons."))
        }
        let goal = Self.cleaned(raw).isEmpty ? record.summary : Self.cleaned(raw)
        return begin(goal: goal, mode: .update(addOnID: record.id, fromVersion: loaded.manifest.version),
                     currentSource: source)
    }

    private func begin(goal: String, mode: AddOnAuthoringSession.Mode, currentSource: String?) -> StartOutcome {
        if let reason = AddOnAuthoringAvailability.unavailable(deps.conditions()) {
            return .refused(AddOnAuthoringAvailability.message(reason))
        }
        if let running = session, running.phase.isBuilding {
            return .refused(String(localized: "I'm already building an add-on for: \(running.goal). Say cancel to stop it."))
        }
        let now = deps.clock.now()
        drafts.sweepExpired(now: now)
        guard AddOnAuthoringAvailability.allowsAnotherSession(starts: drafts.sessionStarts(), now: now) else {
            return .refused(AddOnAuthoringAvailability.message(.dailyLimit))
        }

        var next = AddOnAuthoringSession(goal: goal, mode: mode, startedAt: now)
        next.handle(.begin, now: now)
        var verdict = AddOnAuthoringPreflight.check(goal: goal, native: deps.nativeCapabilities(),
                                                    installed: installedCapabilities(), matcher: deps.matcher)
        if case .update = mode, case .covered = verdict { verdict = .proceed }
        if let message = AddOnAuthoringPreflight.message(for: verdict) {
            next.handle(.preflightRefused(Self.ending(for: verdict)), now: now)
            session = next
            lastMessage = message
            return .refused(message)
        }
        next.handle(.preflightPassed, now: now)
        drafts.recordSessionStart(at: now)
        session = next
        lastMessage = nil
        log = []
        fetched = []
        let id = next.id
        task = Task { [weak self] in await self?.run(sessionID: id, currentSource: currentSource) }
        return .started(String(localized: "I'll look for a free public service for that, and I'll ask you before I test anything."))
    }

    // MARK: - Status and cancel

    func status() -> String {
        tick()
        if let current = session {
            switch current.phase {
            case .researching, .drafting:
                return String(localized: "I'm looking for a service for: \(current.goal).")
            case .validating, .repairing:
                return String(localized: "I'm writing the add-on for: \(current.goal).")
            case .awaitingTestConsent:
                return String(localized: "It's ready to test. I'm waiting for your OK on the phone.")
            case .testing, .assessing:
                return String(localized: "I'm testing the add-on now.")
            case .awaitingApproval:
                return String(localized: "It works and is waiting for you to approve it on your phone.")
            case .idle, .preflight, .installed, .discarded, .gaveUp:
                break
            }
        }
        if !drafts.drafts.isEmpty {
            return String(localized: "\(drafts.drafts.count) add-on(s) are waiting for you to approve them in Settings, under Add-ons.")
        }
        return lastMessage ?? String(localized: "I'm not building an add-on right now.")
    }

    /// Stop the session, whatever it is doing, and keep nothing.
    func cancel() -> String {
        guard var current = session, !current.phase.isTerminal else {
            return String(localized: "I'm not building an add-on right now.")
        }
        let now = deps.clock.now()
        current.handle(.cancel, now: now)
        session = current
        task?.cancel()
        task = nil
        drafts.remove(id: current.id)
        dismissSheet(for: current.id)
        log = []
        let message = String(localized: "Stopped building the add-on. Nothing was kept.")
        lastMessage = message
        return message
    }

    // MARK: - Drafts waiting for approval

    /// Show a waiting draft's sheet again (from Settings).
    func review(draftID: String) {
        guard let draft = drafts.draft(id: draftID) else { return }
        if deps.clock.now() >= draft.expiresAt {
            drafts.remove(id: draftID)
            return
        }
        present(draft)
    }

    /// Turn a waiting draft down without opening it.
    func discard(draftID: String) {
        drafts.remove(id: draftID)
        dismissSheet(for: draftID)
        if var current = session, current.id == draftID {
            current.handle(.rejected, now: deps.clock.now())
            session = current
        }
    }

    /// The sheet's answer, from `AddOnInstallService`. Either way the draft and its trace go: an
    /// approved add-on lives on only as the installed one.
    func resolve(sessionID: String, installed: Bool) {
        drafts.remove(id: sessionID)
        guard var current = session, current.id == sessionID,
              current.handle(installed ? .approved : .rejected, now: deps.clock.now()) else { return }
        session = current
        lastMessage = installed ? nil : String(localized: "Deleted the add-on draft.")
    }

    /// Wait for the running session (tests).
    func waitForSession() async { await task?.value }

    // MARK: - The run

    private func run(sessionID: String, currentSource: String?) async {
        await deps.announce(String(localized: "Looking for a service for that."))
        guard let draft = await research(sessionID: sessionID, currentSource: currentSource) else { return }
        guard apply(.researchDone, sessionID) else { return }

        let identity = makeIdentity(for: draft)
        var current = draft
        while true {
            guard apply(.draftReceived, sessionID) else { return }
            let prepared: AddOnDraftPreparation.Prepared
            switch prepare(current, identity: identity) {
            case .failure(let problem):
                guard apply(.validationFailed, sessionID), session?.phase == .repairing else { return conclude(sessionID) }
                guard let repaired = await repair(sessionID: sessionID, previous: current.addOn,
                                                  problems: problem.repairLines) else { return }
                current = repaired
                continue
            case .success(let ready):
                prepared = ready
            }
            guard apply(.validationPassed, sessionID) else { return }

            // Before every test, and after every repair: a yes naming exactly the domains it may reach.
            let request = AddOnTestConsentRequest(sessionID: sessionID, addOnName: prepared.manifest.name,
                                                  domains: prepared.manifest.permissions.network)
            let agreed = await deps.consent(request)
            guard isLive(sessionID, in: .awaitingTestConsent) else { return conclude(sessionID) }
            switch agreed {
            case .approved:
                break
            case .declined:
                apply(.consentDeclined, sessionID)
                return conclude(sessionID)
            case .busy:
                apply(.consentNotAsked, sessionID)
                return conclude(sessionID)
            }
            guard apply(.consentGiven, sessionID), spend(.test, sessionID) else { return conclude(sessionID) }

            await deps.announce(String(localized: "Testing it now."))
            let runner = RecipeRunner(transport: deps.transport, clock: deps.clock)
            let trace = await runner.dryRun(prepared.manifest, skill: current.sample.skill,
                                            arguments: current.sample.arguments,
                                            context: deps.runContext(prepared.manifest.permissions),
                                            wearerFacts: deps.wearerFacts())
            guard isLive(sessionID, in: .testing), apply(.testFinished, sessionID) else { return conclude(sessionID) }

            let assessment = DryRunAssessor.assess(trace)
            if assessment.passed {
                guard apply(.assessmentPassed, sessionID) else { return conclude(sessionID) }
                offer(prepared, trace: trace, sample: current.sample, sessionID: sessionID)
                return
            }
            guard apply(.assessmentFailed, sessionID), session?.phase == .repairing else { return conclude(sessionID) }
            var problems = DryRunAssessor.repairLines(assessment)
            problems += trace.steps.compactMap { step in
                step.kind == .extract ? step.value.map { "\(step.path) got: \($0)" } : nil
            }
            guard let repaired = await repair(sessionID: sessionID, previous: prepared.fileBytes,
                                              problems: problems) else { return }
            current = repaired
        }
    }

    /// Search and read until the model drafts, gives up, or runs out of calls.
    private func research(sessionID: String, currentSource: String?) async -> AddOnAuthoringPrompt.Draft? {
        while true {
            guard let live = session, live.id == sessionID, live.phase == .researching else { return nil }
            guard spend(.modelCall, sessionID), let modelSession = session else { conclude(sessionID); return nil }
            let prompt = AddOnAuthoringPrompt.research(
                goal: modelSession.goal, mode: modelSession.mode, currentSource: currentSource, log: log,
                fetchesLeft: AddOnAuthoringSession.maxDocsFetches - modelSession.docsFetches,
                callsLeft: AddOnAuthoringSession.maxModelCalls - modelSession.modelCalls)
            let reply: String
            do {
                reply = try await deps.model.complete(system: AddOnAuthoringPrompt.system, user: prompt)
            } catch {
                end(.modelUnavailable, sessionID)
                return nil
            }
            guard isLive(sessionID, in: .researching) else { conclude(sessionID); return nil }

            switch AddOnAuthoringPrompt.parse(reply) {
            case .search(let query):
                let results = await deps.search(query)
                guard isLive(sessionID, in: .researching) else { conclude(sessionID); return nil }
                log.append(.searched(query: query, results: results))
            case .fetch(let url):
                guard spend(.docsFetch, sessionID) else {
                    log.append(.refused("no more pages can be fetched; draft with what you have"))
                    continue
                }
                do {
                    let page = try await deps.docs.fetch(url)
                    guard isLive(sessionID, in: .researching) else { conclude(sessionID); return nil }
                    fetched.append(page.url)
                    log.append(.fetched(url: page.url.absoluteString, text: page.text))
                } catch {
                    guard isLive(sessionID, in: .researching) else { conclude(sessionID); return nil }
                    log.append(.refused("\(url.host ?? "that page") could not be read"))
                }
            case .draft(let draft):
                return draft
            case .needsKey:
                end(.needsKey, sessionID)
                return nil
            case .giveUp:
                end(.couldNotBuild, sessionID)
                return nil
            case .unreadable:
                log.append(.note("Your last reply was not one JSON object with a known action. Reply with exactly one."))
            }
        }
    }

    /// One repair call. Nil when the session ended (the caller returns).
    private func repair(sessionID: String, previous: Data, problems: [String]) async -> AddOnAuthoringPrompt.Draft? {
        guard let live = session, live.id == sessionID, spend(.modelCall, sessionID) else {
            conclude(sessionID)
            return nil
        }
        let reply: String
        do {
            reply = try await deps.model.complete(system: AddOnAuthoringPrompt.system,
                                                  user: AddOnAuthoringPrompt.repair(goal: live.goal, previous: previous,
                                                                                    problems: problems))
        } catch {
            end(.modelUnavailable, sessionID)
            return nil
        }
        guard isLive(sessionID, in: .repairing) else { conclude(sessionID); return nil }
        switch AddOnAuthoringPrompt.parse(reply) {
        case .draft(let draft):
            return draft
        case .needsKey:
            end(.needsKey, sessionID)
        default:
            end(.couldNotBuild, sessionID)
        }
        return nil
    }

    // MARK: - Pieces

    private struct Identity {
        let id: String
        let version: String
    }

    private func makeIdentity(for draft: AddOnAuthoringPrompt.Draft) -> Identity {
        if case .update(let addOnID, let fromVersion)? = session?.mode {
            return Identity(id: addOnID, version: SelfBuiltIdentity.nextVersion(after: fromVersion))
        }
        let taken = Set(store.installed.map(\.id)).union(drafts.drafts.map(\.addOnID))
        let name = AddOnDraftPreparation.proposedName(draft.addOn) ?? session?.goal ?? ""
        return Identity(id: SelfBuiltIdentity.id(forName: name, taken: taken), version: SelfBuiltIdentity.firstVersion)
    }

    private func prepare(_ draft: AddOnAuthoringPrompt.Draft, identity: Identity)
        -> Result<AddOnDraftPreparation.Prepared, AddOnDraftPreparation.Problem> {
        let names = deps.nativeToolNames()
        let web = SelfBuiltIdentity.authorWeb(claimed: draft.docsPage, fetched: fetched, serviceHosts: [])
        let first = AddOnDraftPreparation.prepare(
            draft.addOn, identity: .init(id: identity.id, version: identity.version, authorWeb: web),
            sample: draft.sample, nativeToolNames: names)
        // With no page read, the sheet's domain is the service's own.
        guard web == nil, case .success(let prepared) = first,
              let serviceWeb = SelfBuiltIdentity.authorWeb(claimed: nil, fetched: [],
                                                           serviceHosts: prepared.manifest.permissions.network) else {
            return first
        }
        return AddOnDraftPreparation.prepare(
            draft.addOn, identity: .init(id: identity.id, version: identity.version, authorWeb: serviceWeb),
            sample: draft.sample, nativeToolNames: names)
    }

    private func offer(_ prepared: AddOnDraftPreparation.Prepared, trace: DryRunTrace,
                       sample: AddOnAuthoringPrompt.Sample, sessionID: String) {
        guard let live = session, live.id == sessionID else { return }
        let now = deps.clock.now()
        var isUpdate = false
        if case .update = live.mode { isUpdate = true }
        let draft = AddOnDraftStore.Draft(
            id: sessionID, goal: live.goal, addOnID: prepared.manifest.id, name: prepared.manifest.name,
            version: prepared.manifest.version, isUpdate: isUpdate, fileBytes: prepared.fileBytes,
            sampleQuestion: sample.question, trace: trace, createdAt: live.startedAt,
            testedAt: live.testedAt ?? now)
        drafts.save(draft)
        present(draft)
        if case .refused(let lines) = install.prompt {
            let message = String(localized: "That add-on can't be installed on this phone. \(lines.first ?? "")")
            lastMessage = message
            drafts.remove(id: sessionID)
            end(.refusedByAdmission, sessionID)
            Task { [deps] in await deps.announce(message) }
            return
        }
        Task { [deps] in await deps.announce(String(localized: "It works. Check your phone to approve it.")) }
    }

    private func present(_ draft: AddOnDraftStore.Draft) {
        let provenance = SelfBuiltAddOnProvenance(sessionID: draft.id, goal: draft.goal, builtAt: draft.testedAt)
        install.receive(draft.fileBytes, origin: .selfBuilt(provenance), tested: AddOnTestedSummary(draft: draft))
    }

    private func dismissSheet(for sessionID: String) {
        guard case .review(let review) = install.prompt, case .selfBuilt(let provenance) = review.origin,
              provenance.sessionID == sessionID else { return }
        install.dismiss()
    }

    private func installedCapabilities() -> [AddOnAuthoringPreflight.Capability] {
        store.installed.filter(\.enabled).map { .init(name: $0.name, summary: $0.summary) }
    }

    // MARK: - Session plumbing

    @discardableResult
    private func apply(_ event: AddOnAuthoringSession.Event, _ sessionID: String) -> Bool {
        guard var current = session, current.id == sessionID else { return false }
        let accepted = current.handle(event, now: deps.clock.now())
        session = current
        return accepted
    }

    private func spend(_ resource: AddOnAuthoringSession.Resource, _ sessionID: String) -> Bool {
        guard var current = session, current.id == sessionID else { return false }
        let allowed = current.spend(resource, now: deps.clock.now())
        session = current
        return allowed
    }

    private func end(_ ending: AddOnAuthoringSession.Ending, _ sessionID: String) {
        apply(.end(ending), sessionID)
        conclude(sessionID)
    }

    /// Whether this run's session is still current and in `phase`; lets time pass first.
    private func isLive(_ sessionID: String, in phase: AddOnAuthoringSession.Phase) -> Bool {
        tick()
        guard let current = session, current.id == sessionID else { return false }
        return current.phase == phase
    }

    private func tick() {
        guard var current = session else { return }
        if current.tick(now: deps.clock.now()) {
            session = current
            if current.ending == .expired { drafts.remove(id: current.id) }
        }
    }

    /// After a session ends: delete anything it left, and say why once.
    private func conclude(_ sessionID: String) {
        tick()
        guard let current = session, current.id == sessionID, current.phase.isTerminal,
              current.phase != .installed else { return }
        drafts.remove(id: sessionID)
        log = []
        guard lastMessage == nil, let ending = current.ending, let message = Self.message(for: ending) else { return }
        lastMessage = message
        guard ending != .cancelled, ending != .rejected else { return }
        Task { [deps] in await deps.announce(message) }
    }

    // MARK: - Words

    static func message(for ending: AddOnAuthoringSession.Ending) -> String? {
        switch ending {
        case .covered, .reachesPrivateData, .needsBuiltIn:
            return nil   // said when the session was refused at the start
        case .needsKey:
            return String(localized: "That service needs an account key; I can't build that yet.")
        case .couldNotBuild:
            return String(localized: "I couldn't build a working add-on for that, so nothing was kept.")
        case .notReliable:
            return String(localized: "I couldn't get that service to answer reliably, so I've deleted the draft.")
        case .limitReached, .tookTooLong:
            return String(localized: "Building that took too long, so I've stopped and deleted the draft.")
        case .consentDeclined:
            return String(localized: "OK, I won't test it. The draft is deleted.")
        case .consentNotAsked:
            return String(localized: "I couldn't ask you about testing it, because another confirmation is already on screen. The draft is deleted; ask me again once that one is answered.")
        case .rejected:
            return String(localized: "Deleted the add-on draft.")
        case .expired:
            return String(localized: "The add-on waited a day without approval, so it was deleted.")
        case .cancelled:
            return String(localized: "Stopped building the add-on. Nothing was kept.")
        case .refusedByAdmission:
            return String(localized: "That add-on can't be installed on this phone.")
        case .modelUnavailable:
            return String(localized: "I couldn't reach the model I build add-ons with, so nothing was kept.")
        }
    }

    static func ending(for verdict: AddOnAuthoringPreflight.Verdict) -> AddOnAuthoringSession.Ending {
        switch verdict {
        case .covered(let capability): return .covered(capability.name)
        case .reachesPrivateData: return .reachesPrivateData
        case .needsBuiltIn, .empty, .proceed: return .needsBuiltIn
        }
    }

    static func cleaned(_ goal: String) -> String {
        let flat = goal.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" }).joined(separator: " ")
        return String(flat.prefix(maxGoalLength))
    }
}
