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
/// - **An administrator phone** is an ordinary enrolled phone that kept the card's secret, in the
///   Keychain and never in a backup. It shows the full view while the kept secret matches the
///   profile's current card; a renewal carrying a new card drops it back to the technician's view
///   until the new card is scanned. It can show the card, behind the device owner, for a
///   technician's phone to scan.
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
        var loadCardSecret: () -> String? = { KeychainService.string(for: AdminGate.cardSecretKey) }
        var saveCardSecret: (String?) -> Void = { _ = KeychainService.setString($0, for: AdminGate.cardSecretKey) }
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
    /// Keychain, `…ThisDeviceOnly`: the card secret an administrator phone keeps.
    nonisolated static let cardSecretKey = "orgAdminCardSecret"

    static let shared = AdminGate()

    /// Whether an administrator session is open right now.
    @Published private(set) var sessionActive = false
    private var lastActivity: Date?
    private let seams: Seams
    /// The kept card secret, read from the Keychain once rather than on every redraw.
    private lazy var keptSecret: String? = seams.loadCardSecret()

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// The edition in force and how it opens, or nil on a phone without one.
    var policy: AdminPolicy? { seams.policy() }

    /// Whether the technician's view is what this phone shows right now. Read-only — a session
    /// that has idled out counts as closed here, and `refresh()` makes that official.
    var isRestricted: Bool {
        policy != nil && !isSessionLive && !isAdministratorPhone
    }

    // MARK: - The administrator phone

    /// This phone kept the organisation's current admin card: the full view, all the time.
    var isAdministratorPhone: Bool {
        guard let digest = policy?.credentials.cardDigest, let secret = keptSecret else { return false }
        return AdminSecrets.constantTimeEqual(AdminSecrets.cardDigest(secret: secret), digest)
    }

    /// This phone kept a card the organisation has since replaced — it asks for the new one.
    var keptCardIsStale: Bool {
        keptSecret != nil && policy?.credentials.cardDigest != nil && !isAdministratorPhone
    }

    /// The card, as its QR carries it, for a technician's phone to scan. Only on an administrator
    /// phone, and the caller has already passed the device owner's gate, failing closed.
    var cardToShow: String? {
        guard isAdministratorPhone, let secret = keptSecret else { return nil }
        return AdminSecrets.cardPrefix + secret
    }

    /// "Stop being an administrator phone": the kept secret is deleted.
    func stopBeingAdministratorPhone() {
        objectWillChange.send()
        keptSecret = nil
        seams.saveCardSecret(nil)
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
    /// `remember` makes this an administrator phone once the card is accepted.
    func tryCard(_ scanned: String, remember: Bool = false) -> Attempt {
        guard let policy, let digest = policy.credentials.cardDigest else { return .notApplicable }
        guard let secret = AdminSecrets.cardSecret(from: scanned) else { return .notApplicable }
        if let until = waitUntil { return .waiting(until: until) }
        let attempt = settle(AdminSecrets.constantTimeEqual(AdminSecrets.cardDigest(secret: secret), digest))
        if attempt == .granted, remember {
            objectWillChange.send()
            keptSecret = secret
            seams.saveCardSecret(secret)
        }
        return attempt
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
