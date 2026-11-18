import Foundation

/// One "build yourself a skill for that" session, as a pure state machine.
///
/// `idle → preflight → researching → drafting → validating ⇄ repairing → awaitingTestConsent →
/// testing → assessing ⇄ repairing → awaitingApproval → installed | discarded | gaveUp`.
///
/// Every transition is a function of the state and one event; an event that doesn't fit the
/// current phase changes nothing and reports `false`, so the service can't skip a step (there is
/// no way from `validating` to `testing` except through `awaitingTestConsent` and a yes).
///
/// Hard caps, all enforced here:
/// - 10 model calls, 3 documentation fetches, and 10 minutes of wall clock before the draft is
///   tested and waiting for approval;
/// - 1 test run per draft revision (a repair is a new revision, and each test needs its own yes);
/// - 2 repairs, shared between validation failures and failed tests;
/// - an untested-or-unapproved draft waiting for approval expires 24 hours after its test.
struct AddOnAuthoringSession: Equatable, Sendable {

    enum Mode: Codable, Equatable, Sendable {
        case create
        /// A new version of an add-on the assistant built: same id, version + 1, the update sheet.
        case update(addOnID: String, fromVersion: String)
    }

    enum Phase: String, Codable, Equatable, Sendable, CaseIterable {
        case idle, preflight, researching, drafting, validating, repairing, awaitingTestConsent
        case testing, assessing, awaitingApproval, installed, discarded, gaveUp

        var isTerminal: Bool { self == .installed || self == .discarded || self == .gaveUp }
        /// Building, before a tested draft waits for the wearer: what the wall clock covers.
        var isBuilding: Bool { !isTerminal && self != .idle && self != .awaitingApproval }
    }

    enum Resource: String, Codable, Equatable, Sendable {
        case modelCall, docsFetch, test
    }

    /// Why a session ended other than by being installed.
    enum Ending: Codable, Equatable, Sendable {
        case covered(String)
        case reachesPrivateData
        case needsBuiltIn
        /// Every suitable service needs an account key.
        case needsKey
        /// The model gave up, or the draft still broke the rules after the repairs.
        case couldNotBuild
        /// The test still failed after the repairs.
        case notReliable
        case limitReached(Resource)
        case tookTooLong
        /// The wearer said no to the test.
        case consentDeclined
        /// The wearer wasn't asked about the test: another confirmation was on screen.
        case consentNotAsked
        /// The wearer turned it down on the sheet.
        case rejected
        case expired
        case cancelled
        /// Admission refused the finished file (an organisation ceiling, say).
        case refusedByAdmission
        /// The assistant's model couldn't be reached.
        case modelUnavailable
    }

    enum Event: Equatable, Sendable {
        case begin
        case preflightPassed
        case preflightRefused(Ending)
        /// The model returned a draft: research is over.
        case researchDone
        /// A draft (first or repaired) is ready to check.
        case draftReceived
        case validationFailed
        case validationPassed
        case consentGiven
        case consentDeclined
        /// The consent prompt could not be shown: another confirmation was on screen.
        case consentNotAsked
        case testFinished
        case assessmentPassed
        case assessmentFailed
        case approved
        case rejected
        /// The session ends early for a reason of its own (a keyed API, the model gave up…).
        case end(Ending)
        case cancel
    }

    static let maxModelCalls = 10
    static let maxDocsFetches = 3
    static let maxTestsPerRevision = 1
    static let maxRepairs = 2
    static let wallClock: TimeInterval = 10 * 60
    static let draftLifetime: TimeInterval = 24 * 60 * 60

    let id: String
    let goal: String
    let mode: Mode
    let startedAt: Date
    private(set) var phase: Phase = .idle
    private(set) var ending: Ending?
    private(set) var modelCalls = 0
    private(set) var docsFetches = 0
    private(set) var repairsUsed = 0
    /// 1 for the first draft; each repair adds one.
    private(set) var revision = 1
    private(set) var testsThisRevision = 0
    private(set) var testedAt: Date?

    init(id: String = UUID().uuidString, goal: String, mode: Mode = .create, startedAt: Date) {
        self.id = id
        self.goal = goal
        self.mode = mode
        self.startedAt = startedAt
    }

    var repairsLeft: Int { Self.maxRepairs - repairsUsed }
    var expiresAt: Date? { testedAt.map { $0.addingTimeInterval(Self.draftLifetime) } }

    // MARK: - Events

    /// Apply one event. `false` (and no change) when it doesn't fit the current phase.
    @discardableResult
    mutating func handle(_ event: Event, now: Date) -> Bool {
        if case .cancel = event {
            guard !phase.isTerminal else { return false }
            finish(.discarded, .cancelled)
            return true
        }
        if case .end(let ending) = event {
            // While building, or a tested draft the finished file can't be offered for.
            guard phase.isBuilding || phase == .awaitingApproval else { return false }
            finish(.gaveUp, ending)
            return true
        }
        guard !phase.isTerminal else { return false }
        if phase.isBuilding && isOverTime(now) {
            finish(.gaveUp, .tookTooLong)
            return false
        }

        switch (phase, event) {
        case (.idle, .begin):
            phase = .preflight
        case (.preflight, .preflightPassed):
            phase = .researching
        case (.preflight, .preflightRefused(let ending)):
            finish(.gaveUp, ending)
        case (.researching, .researchDone):
            phase = .drafting
        case (.drafting, .draftReceived), (.repairing, .draftReceived):
            phase = .validating
        case (.validating, .validationFailed):
            repairOrGiveUp(.couldNotBuild)
        case (.validating, .validationPassed):
            phase = .awaitingTestConsent
        case (.awaitingTestConsent, .consentGiven):
            phase = .testing
        case (.awaitingTestConsent, .consentDeclined):
            finish(.discarded, .consentDeclined)
        case (.awaitingTestConsent, .consentNotAsked):
            finish(.discarded, .consentNotAsked)
        case (.testing, .testFinished):
            phase = .assessing
        case (.assessing, .assessmentPassed):
            phase = .awaitingApproval
            testedAt = now
        case (.assessing, .assessmentFailed):
            repairOrGiveUp(.notReliable)
        case (.awaitingApproval, .approved):
            phase = .installed
        case (.awaitingApproval, .rejected):
            finish(.discarded, .rejected)
        default:
            return false
        }
        return true
    }

    /// Use one of a capped resource. `false` when it may not be used: a model call or a test past
    /// its cap, or anything once the wall clock has run out, ends the session; a fourth docs fetch
    /// is only refused (the model is told to draft with what it has).
    @discardableResult
    mutating func spend(_ resource: Resource, now: Date) -> Bool {
        guard phase.isBuilding else { return false }
        if isOverTime(now) {
            finish(.gaveUp, .tookTooLong)
            return false
        }
        switch resource {
        case .modelCall:
            guard [.researching, .drafting, .repairing].contains(phase) else { return false }
            guard modelCalls < Self.maxModelCalls else {
                finish(.gaveUp, .limitReached(.modelCall))
                return false
            }
            modelCalls += 1
        case .docsFetch:
            guard phase == .researching, docsFetches < Self.maxDocsFetches else { return false }
            docsFetches += 1
        case .test:
            guard phase == .testing else { return false }
            guard testsThisRevision < Self.maxTestsPerRevision else {
                finish(.gaveUp, .limitReached(.test))
                return false
            }
            testsThisRevision += 1
        }
        return true
    }

    /// Let time pass: a session still building after ten minutes gives up, and a tested draft
    /// nobody approved within a day expires.
    @discardableResult
    mutating func tick(now: Date) -> Bool {
        if phase.isBuilding, isOverTime(now) {
            finish(.gaveUp, .tookTooLong)
            return true
        }
        if phase == .awaitingApproval, let expiresAt, now >= expiresAt {
            finish(.discarded, .expired)
            return true
        }
        return false
    }

    func isOverTime(_ now: Date) -> Bool { now.timeIntervalSince(startedAt) > Self.wallClock }

    // MARK: - Private

    private mutating func repairOrGiveUp(_ ending: Ending) {
        guard repairsUsed < Self.maxRepairs else {
            finish(.gaveUp, ending)
            return
        }
        repairsUsed += 1
        revision += 1
        testsThisRevision = 0
        phase = .repairing
    }

    private mutating func finish(_ terminal: Phase, _ ending: Ending) {
        phase = terminal
        self.ending = ending
    }
}
