import Combine
import Foundation
import UIKit

/// "Record this job" (Plan HE §1): starts and stops a recording of the open job, keeps it on one
/// clock, and seals it for the office when it stops.
///
/// # What it promises
///
/// - **It fails closed.** No current pairing with an office, no consent, an organisation that
///   forbids it or requires a blur the app cannot apply, Medical Compliance on, too much already
///   waiting, no camera — each is a refusal with a sentence, and nothing is recorded. The same
///   rules are asked again every second while it runs (`JobRecordingAvailability.mustStop`).
/// - **Where the organisation requires faces blurred, nothing unblurred is sealed.** Each recorded
///   part goes through the blur pass first; the bundle is made only of parts the journal says
///   were blurred and checked, and is not made at all while an unblurred part is still in the
///   folder. When the blur cannot run — the app is not in front — the recording waits.
/// - **The frames are raw, and they go to one place.** The recorder is handed the camera's own
///   publisher (`OutboundFrameConsumer.jobRecordingCapture`) and a file inside the job's own
///   folder. There is no call here to a share sheet, to Photos, to the Recordings folder or to a
///   report: the only thing this type does with a finished recording is seal it into the bundle
///   that goes to the office.
/// - **One recording a job, in parts.** A stall, a pause, or the app being closed and the
///   recording carried on begins a new part, and the gap is written down with its reason.
/// - **Nothing is lost quietly.** A recording the app was closed in the middle of keeps the parts
///   that had finished; one that cannot be sealed yet — the pairing is not current — stays on the
///   phone and is sealed when it can be.
///
/// Everything device-facing is a seam, so the whole path runs headless against a fake recorder and
/// a fake clock.
@MainActor
final class JobRecordingCoordinator: ObservableObject {

    // MARK: - What a screen sees

    enum Status: Equatable {
        case idle
        case recording(sessionID: String)
        case paused(sessionID: String)
        /// The glasses stopped sending pictures. The part is saved; a new one begins when they
        /// come back.
        case waitingForVideo(sessionID: String)

        /// The job being recorded, when one is.
        var sessionID: String? {
            switch self {
            case .idle: return nil
            case let .recording(id), let .paused(id), let .waitingForVideo(id): return id
            }
        }

        /// A recording is under way: running, paused, or waiting for the glasses.
        var isActive: Bool { self != .idle }
    }

    @Published private(set) var status: Status = .idle
    /// The jobs whose stopped recordings are being transcribed and sealed right now. Sealing a
    /// long recording takes minutes, and does not hold up recording another job meanwhile.
    @Published private(set) var preparing: Set<String> = []
    /// The jobs whose recordings must have faces blurred and are waiting for the app to be open
    /// to do it: the blur runs only in the foreground.
    @Published private(set) var deferredForBlur: Set<String> = []
    /// How far the blurring of a recording being prepared has got, 0…1.
    @Published private(set) var blurProgress: [String: Double] = [:]
    /// Seconds since this recording began, pauses included.
    @Published private(set) var elapsed: TimeInterval = 0
    /// The media this recording holds so far.
    @Published private(set) var recordedBytes: Int64 = 0
    /// What last happened, as a sentence — stopped at the limit, saved and waiting to be prepared.
    @Published private(set) var lastNote: String?
    /// The job that sentence is about, so another job's page does not show it.
    @Published private(set) var lastNoteSessionID: String?
    /// Whether recording is offered now, as last worked out by `refresh()`.
    @Published private(set) var verdict: JobRecordingAvailability.Verdict = .notOffered
    /// A recording of the open job that is on this phone and not sealed, when no recording is
    /// running: one the app was closed in the middle of, or one still to be prepared.
    @Published private(set) var unsealed: Unsealed?

    enum Unsealed: Equatable {
        /// The app was closed while it ran. It can be carried on, or finished as it is.
        case interrupted
        /// Stopped, and waiting to be prepared for the office.
        case waitingToPrepare
    }

    // MARK: - Seams

    /// The job a recording belongs to.
    struct OpenJob: Equatable, Sendable {
        let sessionID: String
        let jobNumber: String?
    }

    /// The rules that can be read at once, without asking the pairing gate.
    struct Rules: Equatable, Sendable {
        var officeTransportInBuild: Bool
        var fieldAssistEntitled: Bool
        var organizationForbidsRecording: Bool
        var organizationRequiresBlur: Bool
        var medicalComplianceMode: Bool
        var officeRouteRefused: Bool
    }

    struct Seams {
        var rules: @MainActor () -> Rules
        /// The binding held, from the pairing gate passing at this moment. Nil when it does not.
        var binding: @MainActor () async -> BundleManifest.Binding?
        var job: @MainActor () -> OpenJob?

        var consent: @MainActor () -> RecordingConsent.Acknowledgement?
        var saveConsent: @MainActor (RecordingConsent.Acknowledgement?) -> Void

        var recorder: any JobPartRecording
        /// The camera's own publisher: raw. See `OutboundFrameConsumer.jobRecordingCapture`.
        var frames: @MainActor () -> PassthroughSubject<UIImage, Never>
        /// Is the camera producing pictures right now?
        var readiness: @MainActor () -> CameraReadiness? = { nil }
        /// Claim the glasses stream and wait for pictures. The default reports a failed claim, so
        /// a coordinator with no camera wired refuses.
        var ensureStream: @MainActor () async -> ClipStreamWarmup.Result = { .claimFailed }
        var releaseStream: @MainActor () async -> Void = {}

        var capture: JobRecordingCaptureStore
        var bundles: JobRecordingBundleStore
        /// Signs a manifest with the phone's application key.
        var sign: (Data) async throws -> Data
        /// Blurs a recorded part, where the organisation requires it. Nil in an app that cannot:
        /// recording is then refused under that rule, and nothing recorded under it is sealed.
        var blur: JobPartBlur?
        /// The words in one recorded part, timed from that part's own first audio sample.
        var transcribe: @MainActor (URL) async -> [TimedTranscript.Utterance] = { _ in [] }
        /// The job log's lines that belong on a timeline.
        var logEntries: @MainActor (String) -> [RecordedJobAssembly.LogEntry] = { _ in [] }
        /// Writes one line into a job's log: counts and digests, never content.
        var log: @MainActor (String, SessionLogger.Event.Kind, [String: AnyCodable]) -> Void = { _, _, _ in }
        /// Hands the acknowledgement to the compliance audit log, as a consent change.
        var auditConsent: @MainActor (RecordingConsent.Acknowledgement) -> Void = { _ in }
        /// Called once a bundle is sealed, so whatever sends it can look.
        var sealed: @MainActor () -> Void = {}
        /// Takes a job's sealed bundle back out of the office's folder and forgets it there.
        /// Called only when a recording was deleted at the moment it was being sealed and the
        /// seal finished first, and before the bundle's files are removed — which the
        /// coordinator does itself.
        var withdrawSealed: @MainActor (_ sessionID: String) async -> Void = { _ in }

        var limits = RetentionDecision.Limits.standard
        var wallNow: () -> Date = Date.init
        /// The clock the recorder stamps its samples with.
        var monotonicNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var newBundleID: () -> String = JobRecordingBundleStore.newBundleID
    }

    private var seams: Seams

    init(seams: Seams) {
        self.seams = seams
        self.seams.recorder.onStalled = { [weak self] timebase in
            Task { @MainActor in await self?.partStalled(timebase) }
        }
    }

    // MARK: - Whether it is offered

    /// The facts as they stand now, given what the pairing gate just said.
    private func facts(binding: BundleManifest.Binding?) -> JobRecordingAvailability.Facts {
        let rules = seams.rules()
        let job = seams.job()
        let journal = job.flatMap { seams.capture.journal(sessionID: $0.sessionID) }
        let hasBundle = job.map { open in seams.bundles.records().contains { $0.sessionID == open.sessionID } } ?? false
        return .init(
            officeTransportInBuild: rules.officeTransportInBuild,
            fieldAssistEntitled: rules.fieldAssistEntitled,
            officeBindingCurrent: binding != nil,
            organizationForbidsRecording: rules.organizationForbidsRecording,
            organizationRequiresBlur: rules.organizationRequiresBlur,
            blurPassAvailable: seams.blur != nil,
            medicalComplianceMode: rules.medicalComplianceMode,
            officeRouteRefused: rules.officeRouteRefused,
            jobIsOpen: job != nil,
            // A recording that was stopped is this job's recording, sealed yet or not. One the app
            // was closed in the middle of can still be carried on. One whose journal is there and
            // cannot be read is left alone: starting over it would lose what it holds.
            jobAlreadyRecorded: hasBundle || journal?.isStopped == true
                || job.map { preparing.contains($0.sessionID) } == true
                || (journal == nil && job.map { seams.capture.hasJournal(sessionID: $0.sessionID) } == true),
            unsyncedBytes: seams.bundles.unsyncedBytes() + seams.capture.totalBytes())
    }

    /// Works out again whether recording is offered, and what is on the phone for the open job.
    func refresh() async {
        let binding = await seams.binding()
        verdict = JobRecordingAvailability.evaluate(facts(binding: binding), limits: seams.limits)
        refreshUnsealed()
    }

    private func refreshUnsealed() {
        guard !status.isActive, let job = seams.job(), !preparing.contains(job.sessionID),
              let journal = seams.capture.journal(sessionID: job.sessionID) else {
            unsealed = nil
            return
        }
        unsealed = journal.isStopped ? .waitingToPrepare : .interrupted
    }

    /// Whether a job that is not being recorded now has a recording on this phone that is still
    /// to be sealed for the office. For a finished job's page.
    func hasUnsealedRecording(sessionID: String) -> Bool {
        status.sessionID != sessionID && !preparing.contains(sessionID)
            && seams.capture.hasJournal(sessionID: sessionID)
    }

    /// Why a recording that is on this phone, not running and not sealed is not with the office
    /// yet. For the Jobs list and the job-day card, which say it of every such recording and not
    /// only the open job's (Plan HE §4).
    enum Waiting: Equatable {
        /// Being blurred where that is required, transcribed and sealed, now.
        case beingPrepared
        /// Faces have to be blurred first, and that runs only with the app in front.
        case forTheAppToBeOpen
        /// The app was closed while it ran and its job is still open: the technician carries it
        /// on or finishes it.
        case interrupted
        /// Stopped, and prepared on a later pass.
        case toBePrepared

        /// The reason as a sentence — the same words the job's page uses.
        var explanation: String {
            switch self {
            case .beingPrepared: return JobRecordingCoordinator.preparingNote
            case .forTheAppToBeOpen: return BundleSyncState.WaitReason.openAppToPrepare.explanation
            case .interrupted: return JobRecordingCoordinator.interruptedNote
            case .toBePrepared: return JobRecordingCoordinator.sentence(for: .waitingToPrepare, reason: .asked)
            }
        }
    }

    nonisolated static let preparingNote = "Preparing the recording."
    nonisolated static let interruptedNote = "A recording of this job was interrupted. What had been recorded is saved."
    nonisolated static let deletedNote = "The recording was deleted from this phone."

    /// Every recording on this phone that is neither running now nor sealed, by job, with why it
    /// is not with the office yet. One whose journal cannot be read is still a recording.
    func unsealedRecordings() -> [(sessionID: String, waiting: Waiting)] {
        seams.capture.sessionIDsWithJournal().compactMap { sessionID in
            guard sessionID != status.sessionID else { return nil }
            if preparing.contains(sessionID) { return (sessionID, .beingPrepared) }
            if deferredForBlur.contains(sessionID) { return (sessionID, .forTheAppToBeOpen) }
            if let journal = seams.capture.journal(sessionID: sessionID), !journal.isStopped,
               seams.job()?.sessionID == sessionID {
                return (sessionID, .interrupted)
            }
            return (sessionID, .toBePrepared)
        }
    }

    /// Where a stopped recording that is not sealed yet stands: being prepared, or waiting for the
    /// app to be open so that faces can be blurred. Nil for a job with no such recording.
    func preparationPhase(sessionID: String) -> BundleSyncState.Phase? {
        guard status.sessionID != sessionID, seams.capture.hasJournal(sessionID: sessionID) else { return nil }
        var state = BundleSyncState(bundleID: sessionID)
        state.apply(.recordingStopped)
        if deferredForBlur.contains(sessionID), !preparing.contains(sessionID) { state.apply(.preparationDeferred) }
        return state.phase
    }

    // MARK: - Consent

    /// Whether the person holding the phone has acknowledged the consent as it now reads, for the
    /// organisation this phone is paired with.
    func consentStands() async -> Bool {
        guard let binding = await seams.binding() else { return false }
        return RecordingConsent.stands(seams.consent(), organizationID: binding.organizationID, now: seams.wallNow())
    }

    /// Records that the consent was read and acknowledged. False when there is no office to have
    /// consented to recording for.
    @discardableResult
    func acknowledgeConsent() async -> Bool {
        guard let binding = await seams.binding() else { return false }
        let acknowledgement = RecordingConsent.Acknowledgement(at: seams.wallNow(), organizationID: binding.organizationID)
        seams.saveConsent(acknowledgement)
        seams.auditConsent(acknowledgement)
        if let job = seams.job() {
            seams.log(job.sessionID, .recordingConsent, ["wording": AnyCodable(acknowledgement.wordingVersion)])
        }
        return true
    }

    // MARK: - Starting

    /// Why a recording did not start. Every case is a sentence.
    enum Refusal: Error, Equatable {
        /// There is no office to record for; the option should not have been shown.
        case notOffered
        case unavailable(JobRecordingAvailability.Reason)
        /// The consent has not been acknowledged. The screen shows it and asks again.
        case consentRequired
        case alreadyRecording
        case cameraNotReady(String)
        case notEnoughStorage
        case couldNotStart

        var explanation: String {
            switch self {
            case .notOffered:
                return "This phone isn't paired with an office, so there is nowhere for a recording to go."
            case .unavailable(let reason):
                return reason.explanation
            case .consentRequired:
                return "Read what recording a job means first."
            case .alreadyRecording:
                return "A recording is already running."
            case .cameraNotReady(let phrase):
                return "\(phrase), so there's nothing to record. Check the glasses are on, then try again."
            case .notEnoughStorage:
                return "Not enough storage to record — free up some space and try again."
            case .couldNotStart:
                return "The recording couldn't be started."
            }
        }
    }

    /// One change to the recorder at a time. Starting, pausing, carrying on and stopping each wait
    /// for the one before to finish: the recorder must never be asked to begin a part while it is
    /// still finishing the last, and a part being finished must be written down before the
    /// recording is handed on to be sealed. Sealing itself is not one of these — it can take
    /// minutes, and a stop must never wait behind it.
    private var lastChange: Task<Void, Never>?

    private func inTurn<T: Sendable>(_ change: @escaping @MainActor () async -> T) async -> T {
        let previous = lastChange
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await change()
        }
        lastChange = Task { _ = await task.value }
        return await task.value
    }

    /// Start recording the open job, or carry on a recording of it that was interrupted. Returns
    /// the line shown at every start, or why not.
    func start() async -> Result<String, Refusal> {
        await inTurn { await self.startInTurn() }
    }

    private func startInTurn() async -> Result<String, Refusal> {
        guard status == .idle else { return .failure(.alreadyRecording) }

        let binding = await seams.binding()
        verdict = JobRecordingAvailability.evaluate(facts(binding: binding), limits: seams.limits)
        switch verdict {
        case .notOffered: return .failure(.notOffered)
        case .unavailable(let reason): return .failure(.unavailable(reason))
        case .available: break
        }
        guard let binding, let job = seams.job() else { return .failure(.notOffered) }
        guard let consent = seams.consent(),
              RecordingConsent.stands(consent, organizationID: binding.organizationID, now: seams.wallNow()) else {
            return .failure(.consentRequired)
        }

        // The camera has to be producing pictures now, as for a clip: a recording of a stream that
        // is not there is an hour of nothing.
        if seams.readiness()?.hasFreshVisualEvidence != true {
            switch await seams.ensureStream() {
            case .ready:
                holdsStreamClaim = true
            case .timedOut(let phrase):
                await seams.releaseStream()
                return .failure(.cameraNotReady(phrase))
            case .claimFailed:
                return .failure(.cameraNotReady("The glasses camera couldn't be started"))
            }
        }

        do {
            try seams.capture.prepare(sessionID: job.sessionID)
        } catch {
            await releaseClaimedStream()
            return .failure(.couldNotStart)
        }

        let now = seams.wallNow()
        var journal: JobRecordingCaptureStore.Journal
        let resumed: Bool
        if var earlier = seams.capture.journal(sessionID: job.sessionID), !earlier.isStopped {
            // Carrying on a recording the app was closed in the middle of. The part it was writing
            // never finished and does not play; what follows is a new part after a `restart` gap.
            seams.capture.removeUnfinishedParts(earlier)
            if let last = earlier.parts.indices.last, earlier.parts[last].endedBy == nil {
                earlier.parts[last].endedBy = SessionTimeline.GapReason.restart.rawValue
            }
            journal = earlier
            resumed = true
        } else {
            journal = .init(sessionID: job.sessionID, jobNumber: job.jobNumber, wallStart: now, consentAt: consent.at)
            resumed = false
        }
        // What is recorded under the organisation's blur rule is blurred before it is sealed,
        // whatever the rule says by then.
        if seams.rules().organizationRequiresBlur { journal.blurRequired = true }
        // The monotonic clock restarts with the phone, so a carried-on recording joins the old
        // zero through the wall clock: the reading the old zero would have now.
        clock = SessionClock(wallStart: journal.wallStart,
                             monotonicStart: seams.monotonicNow() - now.timeIntervalSince(journal.wallStart))
        self.journal = journal

        if let refusal = beginPart() {
            if !resumed { seams.capture.remove(sessionID: job.sessionID) }
            self.journal = nil
            clock = nil
            await releaseClaimedStream()
            return .failure(refusal)
        }
        status = .recording(sessionID: job.sessionID)
        lastNote = nil
        lastNoteSessionID = nil
        unsealed = nil
        elapsed = 0
        recordedBytes = seams.capture.bytes(sessionID: job.sessionID)
        seams.log(job.sessionID, .recordingStarted, [
            "carried_on": AnyCodable(resumed),
            "consent_wording": AnyCodable(consent.wordingVersion),
        ])
        startTicker()
        return .success(RecordingConsent.reminder)
    }

    // MARK: - The recording under way

    private var journal: JobRecordingCaptureStore.Journal?
    private var clock: SessionClock?
    /// The part being written now.
    private var openPartID: String?
    private var holdsStreamClaim = false
    private var ticker: Timer?
    private var frameWait: AnyCancellable?

    /// Begins the next part. Nil on success; why not otherwise. Leaves the status to the caller.
    private func beginPart() -> Refusal? {
        guard var journal else { return .couldNotStart }
        journal.partsBegun += 1
        let partID = "part-\(journal.partsBegun)"
        let file = seams.capture.partFile(sessionID: journal.sessionID, partID: partID)
        do {
            try seams.recorder.startPart(from: seams.frames(), to: file)
        } catch JobPartStartError.notEnoughStorage {
            return .notEnoughStorage
        } catch {
            return .couldNotStart
        }
        openPartID = partID
        self.journal = journal
        try? seams.capture.save(journal)
        return nil
    }

    /// Writes down the part that just ended. A part that recorded nothing is removed and leaves no
    /// entry: there is nothing of it to place.
    private func closePart(_ timebase: RecordingTimebase?, endedBy reason: SessionTimeline.GapReason?) {
        guard var journal, let clock, let partID = openPartID else { return }
        openPartID = nil
        let file = seams.capture.partFile(sessionID: journal.sessionID, partID: partID)
        let placed = timebase?.placed(partID: partID, on: clock, endedBy: reason)
        if let placed, placed.end != nil, JobRecordingCaptureStore.size(of: file) > 0 {
            seams.capture.protect(partAt: file)
            journal.parts.append(placed)
        } else {
            seams.capture.removePart(sessionID: journal.sessionID, partID: partID)
            // The part before it is now the one a gap follows.
            if let reason, let last = journal.parts.indices.last, journal.parts[last].endedBy == nil {
                journal.parts[last].endedBy = reason.rawValue
            }
        }
        self.journal = journal
        try? seams.capture.save(journal)
        recordedBytes = seams.capture.bytes(sessionID: journal.sessionID)
    }

    /// The recorder ended the part itself: the glasses stopped sending pictures. What was captured
    /// is kept, and a new part begins with the next picture.
    private func partStalled(_ timebase: RecordingTimebase?) async {
        await inTurn {
            guard case .recording(let sessionID) = self.status else { return }
            self.closePart(timebase, endedBy: .stall)
            self.status = .waitingForVideo(sessionID: sessionID)
            self.waitForVideo()
        }
    }

    /// The next picture to arrive begins the next part.
    private func waitForVideo() {
        frameWait = seams.frames().first().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in await self?.videoReturned() }
        }
    }

    /// Pictures are arriving again. Not private so a test can say so without a camera.
    func videoReturned() async {
        let couldNotCarryOn = await inTurn { () -> Bool in
            guard case .waitingForVideo(let sessionID) = self.status else { return false }
            self.frameWait = nil
            guard self.beginPart() == nil else { return true }
            self.status = .recording(sessionID: sessionID)
            return false
        }
        // A recording that cannot begin its next part is finished with what it has, rather than
        // left waiting for something that will not come.
        if couldNotCarryOn { await stop(.couldNotCarryOn) }
    }

    /// Pause: the part is finished and nothing is recorded until `resume()`. The clock keeps
    /// running, and the gap is written down.
    func pause() async {
        await inTurn {
            guard case .recording(let sessionID) = self.status else { return }
            self.status = .paused(sessionID: sessionID)
            self.closePart(await self.seams.recorder.finishPart(), endedBy: .pause)
        }
    }

    /// Carry on after a pause, in a new part. Says why when it cannot.
    @discardableResult
    func resume() async -> Refusal? {
        await inTurn {
            guard case .paused(let sessionID) = self.status else { return nil }
            if let refusal = self.beginPart() {
                self.lastNote = refusal.explanation
                self.lastNoteSessionID = sessionID
                return refusal
            }
            self.status = .recording(sessionID: sessionID)
            return nil
        }
    }

    // MARK: - What is noted as it happens

    /// Puts something on the recording's timeline at this moment: the microphone going live, the
    /// assistant starting or stopping speaking, the capture being silenced, a tool being called.
    /// Does nothing when no recording is under way.
    func note(_ kind: SessionTimeline.EventKind, ref: String? = nil) {
        guard status.isActive, var journal, let clock else { return }
        journal.noted.append(.init(t: clock.time(monotonic: seams.monotonicNow()), kind: kind, ref: ref))
        self.journal = journal
        try? seams.capture.save(journal)
    }

    /// "Mark that": the technician marks this moment for the office. False when nothing is being
    /// recorded.
    @discardableResult
    func mark() -> Bool {
        guard status.isActive else { return false }
        note(.userMarker)
        return true
    }

    // MARK: - The tick

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    /// One second of a running recording: how long and how large it is, and whether it may go on.
    /// Not private: the limits are the behaviour, and a test must not have to wait for them.
    func tick() async {
        guard status.isActive, let journal, let clock else { return }
        elapsed = max(0, clock.time(monotonic: seams.monotonicNow()).seconds)
        recordedBytes = seams.capture.bytes(sessionID: journal.sessionID)
        // The job going away underneath a recording is asked here, once a second, rather than
        // hooked onto each of the ways a job can close.
        guard seams.job()?.sessionID == journal.sessionID else {
            await stop(.jobClosed)
            return
        }
        let rules = seams.rules()
        if rules.organizationRequiresBlur, self.journal?.mustBeBlurred == false {
            // The rule came into force while this was being recorded: it is blurred before it is
            // sealed, and stays so whatever the rule says later.
            self.journal?.blurRequired = true
            if let marked = self.journal { try? seams.capture.save(marked) }
        }
        let standing = JobRecordingAvailability.Facts(
            officeTransportInBuild: rules.officeTransportInBuild, fieldAssistEntitled: rules.fieldAssistEntitled,
            officeBindingCurrent: true, organizationForbidsRecording: rules.organizationForbidsRecording,
            organizationRequiresBlur: rules.organizationRequiresBlur, blurPassAvailable: seams.blur != nil,
            medicalComplianceMode: rules.medicalComplianceMode, officeRouteRefused: rules.officeRouteRefused,
            jobIsOpen: true, jobAlreadyRecorded: false, unsyncedBytes: 0)
        if let reason = JobRecordingAvailability.mustStop(standing) {
            await stop(.noLongerAllowed(reason))
            return
        }
        if RetentionDecision.mustStopRecording(sessionBytes: recordedBytes, limits: seams.limits) {
            await stop(.reachedLimit)
        }
    }

    // MARK: - Stopping

    enum StopReason: Equatable {
        case asked
        case reachedLimit
        case jobClosed
        case noLongerAllowed(JobRecordingAvailability.Reason)
        /// The app was closed while it ran; it is being finished from what it had.
        case interrupted
        /// The glasses came back and a new part could not be begun.
        case couldNotCarryOn

        /// The reason as the job log records it: a fixed word, never a sentence.
        var token: String {
            switch self {
            case .asked: return "asked"
            case .reachedLimit: return "size_limit"
            case .jobClosed: return "job_closed"
            case .noLongerAllowed: return "not_allowed"
            case .interrupted: return "interrupted"
            case .couldNotCarryOn: return "could_not_carry_on"
            }
        }
    }

    /// What came of stopping.
    enum Outcome: Equatable {
        /// Sealed for the office.
        case sealed(bundleID: String)
        /// Saved on the phone; it could not be sealed yet and will be tried again.
        case waitingToPrepare
        /// Saved on the phone, with faces still to be blurred: that runs only while the app is
        /// open, and is done the next time it is.
        case waitingForBlur
        /// Nothing had been recorded, so there is nothing to keep.
        case nothingRecorded
        /// The technician deleted it while it was being prepared. Nothing of it is kept.
        case deleted
    }

    /// Stop the recording and seal it. Nil when nothing was being recorded.
    @discardableResult
    func stop(_ reason: StopReason = .asked) async -> Outcome? {
        guard let journal = await inTurn({ await self.stopCapture(reason) }) else { return nil }
        let outcome = await seal(journal)
        lastNote = Self.sentence(for: outcome, reason: reason, droppedFrames: droppedAtSeal[journal.sessionID] ?? 0)
        lastNoteSessionID = journal.sessionID
        refreshUnsealed()
        return outcome
    }

    /// Ends the capture: the part being written is finished and written down, the glasses are
    /// given back, and the journal says the recording has stopped. From here nothing more is
    /// recorded, whatever becomes of the sealing.
    private func stopCapture(_ reason: StopReason) async -> JobRecordingCaptureStore.Journal? {
        guard status.isActive, journal != nil, let clock else { return nil }
        ticker?.invalidate()
        ticker = nil
        frameWait = nil
        if openPartID != nil {
            closePart(await seams.recorder.finishPart(), endedBy: nil)
        }
        await releaseClaimedStream()
        // Read only now: what was noted while the part was being finished is in it.
        guard var journal else { return nil }

        journal.stoppedAt = max(clock.time(monotonic: seams.monotonicNow()), journal.parts.compactMap(\.end).max() ?? .zero)
        try? seams.capture.save(journal)
        self.journal = nil
        self.clock = nil
        status = .idle
        logStopped(journal, reason: reason)
        return journal
    }

    private func logStopped(_ journal: JobRecordingCaptureStore.Journal, reason: StopReason) {
        seams.log(journal.sessionID, .recordingStopped, [
            "reason": AnyCodable(reason.token),
            "parts": AnyCodable(journal.parts.count),
            "bytes": AnyCodable(Int(seams.capture.bytes(sessionID: journal.sessionID))),
            "seconds": AnyCodable(Int((journal.stoppedAt ?? .zero).seconds.rounded())),
        ])
    }

    nonisolated static func sentence(for outcome: Outcome, reason: StopReason, droppedFrames: Int64 = 0) -> String {
        let lead: String
        switch reason {
        case .asked: lead = ""
        case .reachedLimit: lead = RetentionDecision.stoppedAtLimitNote + " "
        case .jobClosed: lead = "The job closed, so the recording stopped. "
        case .noLongerAllowed(let why): lead = "The recording stopped. " + why.explanation + " "
        case .interrupted: lead = "The recording was interrupted. "
        case .couldNotCarryOn: lead = "The recording couldn't carry on, so it stopped. "
        }
        switch outcome {
        case .sealed:
            // Pictures the blur could not process are left out, and the technician is told.
            let left = droppedFrames > 0 ? " Some of the video couldn't have faces blurred and was left out." : ""
            return lead + "The recording is ready to go to the office." + left
        case .waitingToPrepare:
            return lead + "The recording is saved on this phone, and will be prepared for the office later."
        case .waitingForBlur:
            return lead + "The recording is saved on this phone. Faces have to be blurred before it goes to the office. "
                + BundleSyncState.WaitReason.openAppToPrepare.explanation
        case .nothingRecorded:
            return lead + "Nothing was recorded, so there is nothing to send."
        case .deleted:
            return lead + deletedNote
        }
    }

    // MARK: - Sealing

    /// Seals every recording on this phone that is finished and not sealed: one that could not be
    /// sealed when it stopped, and one the app was closed in the middle of whose job has since
    /// closed. A recording of the job that is still open is left to be carried on. Safe to repeat.
    func sealPending() async {
        let now = seams.wallNow()
        for var journal in seams.capture.journals()
        where journal.sessionID != status.sessionID && !preparing.contains(journal.sessionID) {
            if let retry = sealRetryAfter[journal.sessionID], now < retry { continue }
            // Deleted while an earlier recording in this pass was being sealed: there is nothing
            // of it to stop, write down or seal.
            guard seams.capture.hasJournal(sessionID: journal.sessionID) else { continue }
            if !journal.isStopped {
                guard seams.job()?.sessionID != journal.sessionID else { continue }
                seams.capture.removeUnfinishedParts(journal)
                journal.stoppedAt = journal.parts.compactMap(\.end).max() ?? .zero
                try? seams.capture.save(journal)
                logStopped(journal, reason: .interrupted)
            }
            let outcome = await seal(journal)
            // What the job's page last said about this recording is no longer how it stands.
            if lastNoteSessionID == journal.sessionID, outcome != .waitingToPrepare {
                lastNote = Self.sentence(for: outcome, reason: .asked,
                                         droppedFrames: droppedAtSeal[journal.sessionID] ?? 0)
            }
        }
        refreshUnsealed()
    }

    /// Finish a recording of the open job that the app was closed in the middle of, as it is.
    @discardableResult
    func finishInterrupted() async -> Outcome? {
        let stopped = await inTurn { () -> JobRecordingCaptureStore.Journal? in
            guard self.status == .idle, let job = self.seams.job(),
                  var journal = self.seams.capture.journal(sessionID: job.sessionID), !journal.isStopped,
                  !self.preparing.contains(job.sessionID) else { return nil }
            self.seams.capture.removeUnfinishedParts(journal)
            journal.stoppedAt = journal.parts.compactMap(\.end).max() ?? .zero
            try? self.seams.capture.save(journal)
            self.logStopped(journal, reason: .interrupted)
            return journal
        }
        guard let stopped else { return nil }
        let outcome = await seal(stopped)
        lastNote = Self.sentence(for: outcome, reason: .interrupted,
                                 droppedFrames: droppedAtSeal[stopped.sessionID] ?? 0)
        lastNoteSessionID = stopped.sessionID
        refreshUnsealed()
        return outcome
    }

    /// When a recording that could not be sealed may next be tried. Sealing transcribes the whole
    /// recording, so one that keeps failing — the phone is full — is not tried on every pass.
    private var sealRetryAfter: [String: Date] = [:]
    static let sealRetryInterval: TimeInterval = 15 * 60

    /// How many pictures the blur left out of each recording sealed in this run of the app, for
    /// the sentence that says so.
    private var droppedAtSeal: [String: Int64] = [:]

    /// Blurs a stopped recording where the organisation requires it, transcribes it, puts its
    /// timeline together and seals the bundle. The recorded parts are removed only once the
    /// bundle is sealed — or, for an unblurred part, once its blurred replacement is whole and
    /// written down; on any failure they stay.
    @discardableResult
    private func seal(_ stopped: JobRecordingCaptureStore.Journal) async -> Outcome {
        let sessionID = stopped.sessionID
        // One sealing of a recording at a time: a pass that finds it already under way leaves it.
        guard preparing.insert(sessionID).inserted else { return .waitingToPrepare }
        // A task of its own, whoever asked for it: deleting the recording stops this pass and
        // nothing else (`deleteUnsealed`).
        let pass = Task { @MainActor () -> Outcome in
            let outcome = await self.prepareAndSeal(stopped)
            // Cleared here, before anybody waiting for the pass hears that it has ended.
            self.passes[sessionID] = nil
            self.preparing.remove(sessionID)
            self.blurProgress[sessionID] = nil
            return outcome
        }
        passes[sessionID] = pass
        return await pass.value
    }

    /// The passes preparing a recording right now, by job.
    private var passes: [String: Task<Outcome, Never>] = [:]

    /// One pass over one stopped recording. Run only as a pass's own task, so "cancelled" here
    /// means one thing: the technician deleted this recording while it was being prepared. It is
    /// asked after every wait, and from then on nothing more is written, signed or kept.
    private func prepareAndSeal(_ stopped: JobRecordingCaptureStore.Journal) async -> Outcome {
        let sessionID = stopped.sessionID
        // Deleted between stopping and this pass: there is no journal, and nothing is made of
        // what the caller still holds of it.
        guard !Task.isCancelled, seams.capture.hasJournal(sessionID: sessionID) else { return .deleted }
        var journal = stopped

        // The organisation's blur rule as it stands now, as well as how it stood while the job was
        // recorded: a recording that waited is blurred if the rule has come in since, and one
        // made under the rule is blurred even if the rule has gone.
        if seams.rules().organizationRequiresBlur, !journal.mustBeBlurred {
            journal.blurRequired = true
            guard (try? seams.capture.save(journal)) != nil else { return .waitingToPrepare }
        }
        if journal.mustBeBlurred {
            let step = await blurParts(of: &journal)
            if Task.isCancelled { return .deleted }
            switch step {
            case .done:
                deferredForBlur.remove(sessionID)
            case .deferred:
                deferredForBlur.insert(sessionID)
                return .waitingForBlur
            case .failed:
                deferredForBlur.remove(sessionID)
                sealRetryAfter[sessionID] = seams.wallNow().addingTimeInterval(Self.sealRetryInterval)
                return .waitingToPrepare
            }
            // Nothing is sealed as blurred while an unblurred part is still in the folder.
            guard !seams.capture.holdsUnblurredParts(sessionID: sessionID) else {
                sealRetryAfter[sessionID] = seams.wallNow().addingTimeInterval(Self.sealRetryInterval)
                return .waitingToPrepare
            }
        } else {
            deferredForBlur.remove(sessionID)
        }
        let blurred = journal.mustBeBlurred

        /// The file a part is sealed from. Where blur is required that is the blurred part the
        /// journal names, and never the recorder's own file.
        func media(_ part: RecordingTimebase.PlacedPart) -> URL? {
            guard blurred else { return seams.capture.partFile(sessionID: sessionID, partID: part.partID) }
            guard journal.blurredPart(part.partID) != nil else { return nil }
            return seams.capture.blurredPartFile(sessionID: sessionID, partID: part.partID)
        }
        // Only parts that are really there. The timeline and the manifest must name the same ones.
        let parts = journal.parts.filter { part in
            media(part).map { JobRecordingCaptureStore.size(of: $0) > 0 } ?? false
        }
        guard !parts.isEmpty else {
            seams.capture.remove(sessionID: sessionID)
            return .nothingRecorded
        }
        // Nothing is sealed, and nothing signed, on a pairing that does not verify now.
        let held = await seams.binding()
        if Task.isCancelled { return .deleted }
        guard let binding = held else { return .waitingToPrepare }

        var words: [RecordedJobAssembly.PartWords] = []
        for part in parts where part.audio != nil {
            guard let file = media(part) else { continue }
            words.append(.init(partID: part.partID, utterances: await seams.transcribe(file)))
            if Task.isCancelled { return .deleted }
        }
        // The rule may have come into force while the words were being read. An unblurred bundle
        // sealed now could never be sent, and cannot be blurred once it is signed: it is left as
        // it is, and the next pass blurs it.
        if !blurred, seams.rules().organizationRequiresBlur { return .waitingToPrepare }

        let blurRecords = blurred ? (journal.blurred ?? []) : []
        let droppedFrames = BlurredPart.droppedFrames(blurRecords)
        let assembled = RecordedJobAssembly.assemble(
            clock: SessionClock(wallStart: journal.wallStart, monotonicStart: 0), parts: parts,
            noted: journal.noted.compactMap(\.event), log: seams.logEntries(sessionID), words: words,
            endedAt: journal.stoppedAt ?? .zero, blurred: blurRecords)
        do {
            let input = JobRecordingBundleStore.SealInput(
                bundleID: seams.newBundleID(), sessionID: sessionID,
                jobNumber: BundleManifest.writableJobNumber(journal.jobNumber), binding: binding,
                consentAt: journal.consentAt,
                // Blurred means every part listed below came out of the blur pass. Otherwise the
                // organisation does not require it, and nothing here blurs.
                blurred: blurred, droppedFrames: droppedFrames,
                timeline: try assembled.timeline.encoded(), transcript: try assembled.transcript.encoded(),
                parts: parts.compactMap { part -> JobRecordingBundleStore.PartFile? in
                    guard let file = media(part) else { return nil }
                    return JobRecordingBundleStore.PartFile(
                        partID: part.partID, track: part.video != nil ? .video : .audio, container: "mp4", file: file)
                })
            let sign = seams.sign
            let record = try await seams.bundles.seal(input, now: seams.wallNow(), sign: { payload in
                // Nothing is signed for a recording that has been deleted. The store then leaves
                // no bundle: half a bundle is no bundle.
                try Task.checkCancellation()
                return try await sign(payload)
            })
            if Task.isCancelled {
                // Deleted in the moment between its being signed and written down. What was
                // sealed goes too: out of the office's folder, if a pass has already put it
                // there, and off the phone.
                await seams.withdrawSealed(sessionID)
                try? seams.bundles.delete(record)
                return .deleted
            }
            seams.capture.remove(sessionID: sessionID)
            seams.log(sessionID, .recordingBundleSealed, [
                "manifest_sha256": AnyCodable(record.manifestSHA256),
                "chunks": AnyCodable(record.chunks.count),
                "bytes": AnyCodable(Int(record.totalBytes)),
                "parts": AnyCodable(parts.count),
                "utterances": AnyCodable(assembled.transcript.utterances.count),
                "blurred": AnyCodable(blurred),
                "dropped_frames": AnyCodable(Int(droppedFrames)),
            ])
            sealRetryAfter[sessionID] = nil
            droppedAtSeal[sessionID] = droppedFrames
            seams.sealed()
            return .sealed(bundleID: record.bundleID)
        } catch {
            if Task.isCancelled { return .deleted }
            // Everything is still where it was. Tried again later, not on the very next pass.
            sealRetryAfter[sessionID] = seams.wallNow().addingTimeInterval(Self.sealRetryInterval)
            return .waitingToPrepare
        }
    }

    // MARK: - Deleting a recording that is not sealed

    /// The question to put before a recording that has not been sealed is deleted. Only the
    /// coordinator makes one, and `deleteUnsealed` takes nothing else — so there is no way to
    /// delete such a recording without having been handed the question first.
    struct UnsealedDeletion: Equatable {
        let sessionID: String
        /// An unsealed recording has never left this phone, so it is always the only copy.
        let warning: String

        fileprivate init(sessionID: String) {
            self.sessionID = sessionID
            warning = RetentionDecision.unacknowledgedRecordingDeletionWarning
        }
    }

    /// What to ask before deleting a job's recording that is on this phone and not sealed. Nil
    /// when the job has no such recording, and while it is being recorded: a recording that is
    /// running is stopped first, by the person, with the stop control.
    func askToDeleteUnsealed(sessionID: String) -> UnsealedDeletion? {
        guard status.sessionID != sessionID, seams.capture.hasJournal(sessionID: sessionID) else { return nil }
        return UnsealedDeletion(sessionID: sessionID)
    }

    /// Deletes a job's recording that has not been sealed: its recorded parts, blurred or not,
    /// and its journal — and nothing else of the job. False when there was nothing to delete.
    ///
    /// A pass that is preparing the recording is stopped first and waited for, so nothing is
    /// written after the folder has gone: the blur stops at its next frame and removes what it
    /// had written, the words stop being read, and nothing is signed. A pass that had got as far
    /// as sealing removes what it sealed (`prepareAndSeal`).
    @discardableResult
    func deleteUnsealed(_ asked: UnsealedDeletion) async -> Bool {
        let sessionID = asked.sessionID
        // The question may be an old one: the recording carried on since, sealed, or deleted.
        guard status.sessionID != sessionID, seams.capture.hasJournal(sessionID: sessionID) else { return false }
        // What is there when the technician says so: a pass stopped below may have moved it.
        let bytes = seams.capture.bytes(sessionID: sessionID)
        let parts = seams.capture.journal(sessionID: sessionID)?.parts.count ?? 0
        var passDeletedIt = false
        while let pass = passes[sessionID] {
            pass.cancel()
            if await pass.value == .deleted { passDeletedIt = true }
        }
        // Asked again: that was a wait, and the recording may have been carried on in it.
        guard status.sessionID != sessionID else { return false }

        let hadCapture = seams.capture.hasJournal(sessionID: sessionID)
        if hadCapture { seams.capture.delete(sessionID: sessionID) }
        deferredForBlur.remove(sessionID)
        blurProgress[sessionID] = nil
        sealRetryAfter[sessionID] = nil
        droppedAtSeal[sessionID] = nil
        // Nothing unsealed was there and no pass was stopped: sealed before this was asked, or
        // already gone. Nothing was deleted here.
        guard hadCapture || passDeletedIt else { return false }

        seams.log(sessionID, .recordingDeleted, [
            "sealed": AnyCodable(false),
            "acknowledged": AnyCodable(false),
            "parts": AnyCodable(parts),
            "bytes": AnyCodable(Int(bytes)),
        ])
        lastNote = Self.deletedNote
        lastNoteSessionID = sessionID
        await refresh()
        return true
    }

    // MARK: - Blurring

    /// How many recordings are having their parts blurred at this moment.
    private var passesRunning = 0

    private enum BlurStep {
        /// Every part that is there has been blurred, checked and written down.
        case done
        /// The blur cannot run now. Everything is as it was; it is done when the app is next open.
        case deferred
        /// Something went wrong. Everything is as it was; it is tried again later.
        case failed
    }

    /// Puts every recorded part that has not been blurred through the blur pass.
    ///
    /// One part at a time, and each in three steps that can be stopped between any two and done
    /// again: the pass writes a new file beside the unblurred part; the new file takes the blurred
    /// part's name and the journal says so; only then is the unblurred part removed. A blurred
    /// part the journal does not name was never checked, and is made again.
    private func blurParts(of journal: inout JobRecordingCaptureStore.Journal) async -> BlurStep {
        let sessionID = journal.sessionID
        let manager = FileManager.default
        // Whatever is in the folder that the journal does not name is no part of this recording:
        // a file a pass was writing, a blurred file that was never written down, a part that
        // never finished. None of it is kept, and none of it is ever sealed.
        seams.capture.removeBlurScratch(sessionID: sessionID)
        seams.capture.removeUnfinishedParts(journal)
        for part in journal.parts {
            let raw = seams.capture.partFile(sessionID: sessionID, partID: part.partID)
            // Blurred, checked and written down on an earlier pass: the unblurred part goes, if
            // it is still here. So does one with nothing in it.
            if journal.blurredPart(part.partID) != nil || JobRecordingCaptureStore.size(of: raw) == 0 {
                seams.capture.removePart(sessionID: sessionID, partID: part.partID)
            }
        }
        let waiting = journal.parts.filter { part in
            journal.blurredPart(part.partID) == nil
                && JobRecordingCaptureStore.size(of: seams.capture.partFile(sessionID: sessionID, partID: part.partID)) > 0
        }
        guard !waiting.isEmpty else { return .done }
        guard let blur = seams.blur else { return .failed }
        guard blur.isAvailable() else { return .deferred }
        // Blurring a long part takes minutes, and a phone that locks itself stops it. Two
        // recordings can be blurred at once; the phone is let go when the last has finished.
        passesRunning += 1
        if passesRunning == 1 { blur.keepAwake(true) }
        defer {
            passesRunning -= 1
            if passesRunning == 0 { blur.keepAwake(false) }
        }

        for (index, part) in waiting.enumerated() {
            guard blur.isAvailable() else { return .deferred }
            let raw = seams.capture.partFile(sessionID: sessionID, partID: part.partID)
            let scratch = seams.capture.blurScratchFile(sessionID: sessionID, partID: part.partID)
            let finished = seams.capture.blurredPartFile(sessionID: sessionID, partID: part.partID)
            let result = await blur.blur(raw, scratch) { [weak self] fraction in
                self?.blurProgress[sessionID] = (Double(index) + min(1, max(0, fraction))) / Double(waiting.count)
            }
            // The recording was deleted while this part was being blurred: whatever the pass
            // says of it, nothing more is written.
            if Task.isCancelled {
                try? manager.removeItem(at: scratch)
                return .failed
            }
            let report: BlurredPart.Report
            switch result {
            case .success(let made):
                report = made
            case .failure(let failure):
                try? manager.removeItem(at: scratch)
                return failure == .interrupted ? .deferred : .failed
            }

            var next = journal
            next.blurred = (next.blurred ?? []) + [BlurredPart(partID: part.partID, report: report, video: part.video)]
            if report.keptNothing {
                // No picture could be blurred and there was no sound: nothing of this part is kept.
                next.parts.removeAll { $0.partID == part.partID }
            } else if let at = next.parts.firstIndex(where: { $0.partID == part.partID }) {
                next.parts[at] = .init(partID: part.partID, video: report.keptPictures ? part.video : nil,
                                       audio: report.keptSound ? part.audio : nil, endedBy: part.endedBy)
            }
            do {
                if report.keptNothing {
                    try? manager.removeItem(at: scratch)
                } else {
                    guard JobRecordingCaptureStore.size(of: scratch) > 0 else { throw JobPartBlur.Failure.failed }
                    try manager.moveItem(at: scratch, to: finished)
                    seams.capture.protect(partAt: finished)
                }
                try seams.capture.save(next)
            } catch {
                // Not written down, so not a blurred part. The unblurred part is still where it was.
                try? manager.removeItem(at: scratch)
                try? manager.removeItem(at: finished)
                return .failed
            }
            journal = next
            // Only now: its replacement is whole, checked by the pass, and in the journal.
            seams.capture.removePart(sessionID: sessionID, partID: part.partID)
        }
        return .done
    }

    private func releaseClaimedStream() async {
        guard holdsStreamClaim else { return }
        holdsStreamClaim = false
        await seams.releaseStream()
    }
}

// MARK: - The blur seam

/// What blurs one recorded part, as the coordinator needs it (Plan HE §1, "Blur when required").
/// A set of closures so the whole of the joining — when a part is blurred, what waits, what is
/// removed and when — is testable without a decoder, an encoder or a face detector.
struct JobPartBlur {
    enum Failure: Error, Equatable {
        /// The blur stopped being able to run part-way: the app left the foreground, or the phone
        /// was locked. Nothing was kept of the attempt.
        case interrupted
        /// The part could not be read, written or checked. Nothing was kept of the attempt.
        case failed
    }

    /// Whether the blur can run at this moment. It runs only with the app in front.
    var isAvailable: @MainActor () -> Bool
    /// Writes a copy of the part at the first address to the second, every picture through the
    /// face blur and the sound carried over, and reports what it wrote and what it dropped. On a
    /// failure it leaves nothing at the second address. It never touches the first.
    var blur: (_ part: URL, _ output: URL, _ progress: @escaping @MainActor (Double) -> Void) async
        -> Result<BlurredPart.Report, Failure>
    /// Keeps the phone from locking itself while parts are being blurred, and lets it again.
    var keepAwake: @MainActor (Bool) -> Void = { _ in }
}

// MARK: - The recorder seam

/// Why a part could not begin.
enum JobPartStartError: Error, Equatable {
    case notEnoughStorage
    case couldNotStart
}

/// What records one part of a job. A protocol so the coordinator's whole behaviour — refusals,
/// parts, gaps, limits, what is sealed — is testable without a camera or an encoder.
@MainActor
protocol JobPartRecording: AnyObject {
    /// Begin writing a part to `file`, from the frames given, and from the microphone.
    func startPart(from frames: PassthroughSubject<UIImage, Never>, to file: URL) throws
    /// Finish the part. Nil when nothing was written.
    func finishPart() async -> RecordingTimebase?
    /// Called when the recorder ended the part itself because pictures stopped arriving, with
    /// what it knows of the part it ended.
    var onStalled: ((RecordingTimebase?) -> Void)? { get set }
}
