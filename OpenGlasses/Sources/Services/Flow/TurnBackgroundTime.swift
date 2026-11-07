import Foundation

/// A Direct turn's claim on background time (Plan KR P5, owner decision 5).
///
/// The partner's turn went to the background seconds in, with listening already off. Nothing held
/// the app awake, so iOS suspended it mid-request for almost three minutes: about fifteen seconds
/// of work took over two hundred. A turn that is in flight when the app leaves the foreground now
/// runs inside a background task until it ends or iOS's allowance runs out. It only lets a started
/// turn finish; nothing new starts in the background because of it.
///
/// When the allowance runs out the task is ended at once, as iOS requires (a task left open gets
/// the app killed rather than suspended), and the turn simply waits, as it did before, until the
/// app is back.
///
/// A reply that finishes while the app is away and is not spoken is already in the conversation
/// (the turn saves it before speaking). The next foreground says so once.
///
/// Main-actor state, driven by `AppState` at the turn's start and end and on scene changes; iOS is
/// behind `BackgroundTaskRunning`, so the whole lifecycle runs headless.
@MainActor
final class TurnBackgroundTime {
    /// What the next foreground says when a reply finished unspoken while the app was away.
    static let replyWaitingNotice = String(localized: "Your last answer is in the conversation.")

    static let taskName = "direct-turn"

    private let tasks: BackgroundTaskRunning
    /// The open background task, while one is held.
    private var token: Int?
    /// Bumped on every claim, so an expiry from an earlier claim never touches a later one.
    private var claim = 0
    private(set) var turnInFlight = false
    /// Whether the last claim ran out before the turn ended.
    private(set) var expired = false
    /// A reply finished unspoken while the app was away; said once on the next foreground.
    private(set) var replyWaiting = false

    init(tasks: BackgroundTaskRunning = SystemBackgroundTasks()) {
        self.tasks = tasks
    }

    /// Whether a background task is held right now.
    var isHoldingTask: Bool { token != nil }

    /// A Direct turn started. One that starts with the app already away (a shortcut, the Action
    /// Button with the screen off) claims its time at once.
    func turnBegan(appInBackground: Bool) {
        turnInFlight = true
        expired = false
        if appInBackground { claimTime() }
    }

    /// The app left the foreground. A turn in flight claims background time to finish in.
    func appLeftForeground() {
        guard turnInFlight else { return }
        claimTime()
    }

    /// The turn's reply has been handed to speech and come back. `spoken` is whether it was heard
    /// through to its end, as far as the app can tell.
    func replyFinished(spoken: Bool, appInBackground: Bool) {
        guard appInBackground, !spoken else { return }
        replyWaiting = true
        PrivacyLog.app(.turnBackgroundTime, detail: PrivacyToken("replyWaiting"))
    }

    /// The turn ended, on any path. The background task, if one is held, ends with it.
    func turnEnded() {
        turnInFlight = false
        releaseTime()
    }

    /// The app is in front again. Returns the notice to say, once, when a reply finished unspoken
    /// while it was away — and nothing while a turn is still running, which will speak for itself.
    func appReturnedToForeground() -> String? {
        guard replyWaiting, !turnInFlight else { return nil }
        replyWaiting = false
        return Self.replyWaitingNotice
    }

    // MARK: - The task

    private func claimTime() {
        guard token == nil else { return }
        claim += 1
        let thisClaim = claim
        token = tasks.begin(name: Self.taskName) { [weak self] in
            self?.allowanceRanOut(claim: thisClaim)
        }
        PrivacyLog.app(.turnBackgroundTime, detail: PrivacyToken("began"))
    }

    private func releaseTime() {
        guard let token else { return }
        self.token = nil
        tasks.end(token)
        PrivacyLog.app(.turnBackgroundTime, detail: PrivacyToken("ended"))
    }

    /// iOS's allowance ran out: the runner has already ended the task, so it is forgotten, not
    /// ended again. The turn carries on when the app next runs.
    private func allowanceRanOut(claim expiredClaim: Int) {
        guard expiredClaim == claim, token != nil else { return }
        token = nil
        expired = true
        PrivacyLog.app(.turnBackgroundTime, detail: PrivacyToken("expired"))
    }
}
