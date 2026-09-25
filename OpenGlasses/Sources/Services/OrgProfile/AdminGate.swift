import Foundation
import Combine

/// Plan CT 3b — the organisation's administrator gate over what the edition hides.
///
/// It checks a typed passcode against the profile's verifier, or a scanned admin card against its
/// digest, and holds the administrator session that follows. It opens only the hidden view: every
/// ceiling still clamps, whoever is holding the phone.
///
/// - **Backoff, persisted across launches:** five free attempts, then a wait of 30 s that doubles
///   with each further failure, up to an hour. A failed card scan counts the same as a wrong
///   passcode. While a wait runs, nothing is checked at all.
/// - **The session** ends when the app goes to the background, or after ten minutes without
///   activity, whichever comes first; the phone then returns to the technician's view.
/// - **No local reset.** A forgotten passcode or lost card is a re-minted profile, picked up at the
///   next renewal — a local reset would be a way round the gate.
@MainActor
final class AdminGate: ObservableObject {

    nonisolated static let freeAttempts = 5
    nonisolated static let firstWait: TimeInterval = 30
    nonisolated static let longestWait: TimeInterval = 3_600
    nonisolated static let sessionIdleLimit: TimeInterval = 600

    enum Attempt: Equatable {
        case granted
        /// Wrong. `waitUntil` is set once the free attempts are used up.
        case refused(waitUntil: Date?)
        /// Still inside a wait from earlier failures; nothing was checked.
        case waiting(until: Date)
        /// The phone has no edition in force, or the text is not something this gate reads.
        case notApplicable
    }

    struct Seams {
        var now: () -> Date = Date.init
        var policy: @MainActor () -> AdminPolicy? = { OrgProfileManager.shared.adminPolicy }
        var loadFailures: () -> Int = { UserDefaults.standard.integer(forKey: AdminGate.failuresKey) }
        var saveFailures: (Int) -> Void = { UserDefaults.standard.set($0, forKey: AdminGate.failuresKey) }
        var loadWaitUntil: () -> Date? = {
            let stamp = UserDefaults.standard.double(forKey: AdminGate.waitUntilKey)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        var saveWaitUntil: (Date?) -> Void = {
            if let date = $0 {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: AdminGate.waitUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AdminGate.waitUntilKey)
            }
        }
    }

    nonisolated static let failuresKey = "orgAdminFailedAttempts"
    nonisolated static let waitUntilKey = "orgAdminWaitUntil"

    static let shared = AdminGate()

    /// Whether an administrator session is open right now.
    @Published private(set) var sessionActive = false
    private var lastActivity: Date?
    private let seams: Seams

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// The edition in force and how it opens, or nil on a phone without one.
    var policy: AdminPolicy? { seams.policy() }

    /// Whether the technician's view is what this phone shows right now. Read-only — a session
    /// that has idled out counts as closed here, and `refresh()` makes that official.
    var isRestricted: Bool {
        policy != nil && !isSessionLive
    }

    /// An open session that has not idled out.
    var isSessionLive: Bool {
        guard sessionActive, let lastActivity else { return false }
        return seams.now().timeIntervalSince(lastActivity) < Self.sessionIdleLimit
    }

    /// The wait still running from earlier failures, if any.
    var waitUntil: Date? {
        guard let until = seams.loadWaitUntil(), until > seams.now() else { return nil }
        return until
    }

    // MARK: - Attempts

    func tryPasscode(_ passcode: String) -> Attempt {
        guard let policy, let verifier = policy.credentials.passcode else { return .notApplicable }
        if let until = waitUntil { return .waiting(until: until) }
        let derived = AdminSecrets.pbkdf2(passcode, salt: verifier.salt, iterations: verifier.iterations,
                                          length: verifier.hash.count)
        return settle(derived.map { AdminSecrets.constantTimeEqual($0, verifier.hash) } ?? false)
    }

    /// A code read by the in-app scanner. Text that is not an admin card at all is not an attempt.
    func tryCard(_ scanned: String) -> Attempt {
        guard let policy, let digest = policy.credentials.cardDigest else { return .notApplicable }
        guard let secret = AdminSecrets.cardSecret(from: scanned) else { return .notApplicable }
        if let until = waitUntil { return .waiting(until: until) }
        return settle(AdminSecrets.constantTimeEqual(AdminSecrets.cardDigest(secret: secret), digest))
    }

    /// The device owner's own gate passed, on a phone whose profile issued neither a card nor a
    /// passcode (the review sheet said so). The caller ran `OwnerGateAuth`, failing closed.
    func deviceOwnerPassed() -> Attempt {
        guard let policy, policy.credentials.method == .deviceOwner else { return .notApplicable }
        startSession()
        return .granted
    }

    private func settle(_ matched: Bool) -> Attempt {
        if matched {
            seams.saveFailures(0)
            seams.saveWaitUntil(nil)
            startSession()
            return .granted
        }
        let failures = seams.loadFailures() + 1
        seams.saveFailures(failures)
        guard let wait = Self.wait(afterFailures: failures) else { return .refused(waitUntil: nil) }
        let until = seams.now().addingTimeInterval(wait)
        seams.saveWaitUntil(until)
        return .refused(waitUntil: until)
    }

    /// The wait after `failures` failed attempts: none for the first five, then 30 s doubling to an hour.
    nonisolated static func wait(afterFailures failures: Int) -> TimeInterval? {
        guard failures > freeAttempts else { return nil }
        let doublings = min(failures - freeAttempts - 1, 20)
        return min(firstWait * pow(2, Double(doublings)), longestWait)
    }

    // MARK: - The session

    private func startSession() {
        sessionActive = true
        lastActivity = seams.now()
    }

    /// Something happened in administrator settings; the idle clock starts again.
    func noteActivity() {
        guard sessionActive else { return }
        lastActivity = seams.now()
    }

    /// End the session once it has been idle too long.
    func refresh() {
        guard sessionActive, let lastActivity else { return }
        if seams.now().timeIntervalSince(lastActivity) >= Self.sessionIdleLimit { endSession() }
    }

    func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        lastActivity = nil
    }

    /// The app went to the background: the session ends, whatever was open.
    func handleBackground() {
        endSession()
    }
}
