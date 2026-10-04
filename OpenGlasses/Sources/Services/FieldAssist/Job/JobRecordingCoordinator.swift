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
        /// Stopped, and being transcribed and sealed.
        case preparing(sessionID: String)

        /// The job being recorded, when one is.
        var sessionID: String? {
            switch self {
            case .idle: return nil
            case let .recording(id), let .paused(id), let .waitingForVideo(id), let .preparing(id): return id
            }
        }

        /// A recording is under way: running, paused, or waiting for the glasses.
        var isActive: Bool {
            switch self {
            case .recording, .paused, .waitingForVideo: return true
            case .idle, .preparing: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    /// Seconds since this recording began, pauses included.
    @Published private(set) var elapsed: TimeInterval = 0
    /// The media this recording holds so far.
    @Published private(set) var recordedBytes: Int64 = 0
    /// What last happened, as a sentence — stopped at the limit, saved and waiting to be prepared.
    @Published private(set) var lastNote: String?
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

    /// The facts as they stand now. Asks the pairing gate.
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
            medicalComplianceMode: rules.medicalComplianceMode,
            officeRouteRefused: rules.officeRouteRefused,
            jobIsOpen: job != nil,
            // A recording that was stopped is this job's recording, sealed yet or not. One the app
            // was closed in the middle of can still be carried on. One whose journal is there and
            // cannot be read is left alone: starting over it would lose what it holds.
            jobAlreadyRecorded: hasBundle || journal?.isStopped == true
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
        guard !status.isActive, status.sessionID == nil, let job = seams.job(),
              let journal = seams.capture.journal(sessionID: job.sessionID) else {
            unsealed = nil
            return
        }
        unsealed = journal.isStopped ? .waitingToPrepare : .interrupted
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

    private var starting = false

    /// Start recording the open job, or carry on a recording of it that was interrupted. Returns
    /// the line said at every start, or why not.
    func start() async -> Result<String, Refusal> {
        guard status == .idle, !starting else { return .failure(.alreadyRecording) }
        starting = true
        defer { starting = false }

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
        guard case .recording(let sessionID) = status else { return }
        closePart(timebase, endedBy: .stall)
        status = .waitingForVideo(sessionID: sessionID)
        frameWait = seams.frames().first().receive(on: DispatchQueue.main).sink { [weak self] _ in
            Task { @MainActor in self?.videoReturned() }
        }
    }

    /// Pictures are arriving again. Not private so a test can say so without a camera.
    func videoReturned() {
        guard case .waitingForVideo(let sessionID) = status else { return }
        frameWait = nil
        if beginPart() == nil {
            status = .recording(sessionID: sessionID)
        }
        // If the part could not begin, the recording stays waiting; the next tick or the next
        // picture after a stop will say more. Nothing recorded so far is affected.
    }

    /// Pause: the part is finished and nothing is recorded until `resume()`. The clock keeps
    /// running, and the gap is written down.
    func pause() async {
        guard case .recording(let sessionID) = status else { return }
        status = .paused(sessionID: sessionID)
        closePart(await seams.recorder.finishPart(), endedBy: .pause)
    }

    /// Carry on after a pause, in a new part. Says why when it cannot.
    @discardableResult
    func resume() -> Refusal? {
        guard case .paused(let sessionID) = status else { return nil }
        if let refusal = beginPart() {
            lastNote = refusal.explanation
            return refusal
        }
        status = .recording(sessionID: sessionID)
        return nil
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
        let standing = JobRecordingAvailability.Facts(
            officeTransportInBuild: rules.officeTransportInBuild, fieldAssistEntitled: rules.fieldAssistEntitled,
            officeBindingCurrent: true, organizationForbidsRecording: rules.organizationForbidsRecording,
            organizationRequiresBlur: rules.organizationRequiresBlur,
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

        /// The reason as the job log records it: a fixed word, never a sentence.
        var token: String {
            switch self {
            case .asked: return "asked"
            case .reachedLimit: return "size_limit"
            case .jobClosed: return "job_closed"
            case .noLongerAllowed: return "not_allowed"
            case .interrupted: return "interrupted"
            }
        }
    }

    /// What came of stopping.
    enum Outcome: Equatable {
        /// Sealed for the office.
        case sealed(bundleID: String)
        /// Saved on the phone; it could not be sealed yet and will be tried again.
        case waitingToPrepare
        /// Nothing had been recorded, so there is nothing to keep.
        case nothingRecorded
    }

    /// Stop the recording and seal it. Nil when nothing was being recorded.
    @discardableResult
    func stop(_ reason: StopReason = .asked) async -> Outcome? {
        guard status.isActive, var journal, let clock else { return nil }
        let sessionID = journal.sessionID
        status = .preparing(sessionID: sessionID)
        ticker?.invalidate()
        ticker = nil
        frameWait = nil
        if openPartID != nil {
            closePart(await seams.recorder.finishPart(), endedBy: nil)
            journal = self.journal ?? journal
        }
        await releaseClaimedStream()

        journal.stoppedAt = max(clock.time(monotonic: seams.monotonicNow()), journal.parts.compactMap(\.end).max() ?? .zero)
        try? seams.capture.save(journal)
        self.journal = nil
        self.clock = nil
        logStopped(journal, reason: reason)

        let outcome = await seal(journal)
        status = .idle
        lastNote = Self.sentence(for: outcome, reason: reason)
        refreshUnsealed()
        return outcome
    }

    private func logStopped(_ journal: JobRecordingCaptureStore.Journal, reason: StopReason) {
        seams.log(journal.sessionID, .recordingStopped, [
            "reason": AnyCodable(reason.token),
            "parts": AnyCodable(journal.parts.count),
            "bytes": AnyCodable(Int(seams.capture.bytes(sessionID: journal.sessionID))),
            "seconds": AnyCodable(Int((journal.stoppedAt ?? .zero).seconds.rounded())),
        ])
    }

    static func sentence(for outcome: Outcome, reason: StopReason) -> String {
        let lead: String
        switch reason {
        case .asked: lead = ""
        case .reachedLimit: lead = RetentionDecision.stoppedAtLimitNote + " "
        case .jobClosed: lead = "The job closed, so the recording stopped. "
        case .noLongerAllowed(let why): lead = "The recording stopped. " + why.explanation + " "
        case .interrupted: lead = "The recording was interrupted. "
        }
        switch outcome {
        case .sealed:
            return lead + "The recording is ready to go to the office."
        case .waitingToPrepare:
            return lead + "The recording is saved on this phone. It will be prepared for the office "
                + "when this phone can reach its pairing with the office again."
        case .nothingRecorded:
            return lead + "Nothing was recorded, so there is nothing to send."
        }
    }

    // MARK: - Sealing

    /// Seals every recording on this phone that is finished and not sealed: one that could not be
    /// sealed when it stopped, and one the app was closed in the middle of whose job has since
    /// closed. A recording of the job that is still open is left to be carried on. Safe to repeat.
    func sealPending() async {
        guard !sealing else { return }
        for var journal in seams.capture.journals() where journal.sessionID != status.sessionID {
            if !journal.isStopped {
                guard seams.job()?.sessionID != journal.sessionID else { continue }
                seams.capture.removeUnfinishedParts(journal)
                journal.stoppedAt = journal.parts.compactMap(\.end).max() ?? .zero
                try? seams.capture.save(journal)
                logStopped(journal, reason: .interrupted)
            }
            await seal(journal)
        }
        refreshUnsealed()
    }

    /// Finish a recording of the open job that the app was closed in the middle of, as it is.
    @discardableResult
    func finishInterrupted() async -> Outcome? {
        guard status == .idle, let job = seams.job(),
              var journal = seams.capture.journal(sessionID: job.sessionID), !journal.isStopped else { return nil }
        seams.capture.removeUnfinishedParts(journal)
        journal.stoppedAt = journal.parts.compactMap(\.end).max() ?? .zero
        try? seams.capture.save(journal)
        logStopped(journal, reason: .interrupted)
        status = .preparing(sessionID: job.sessionID)
        let outcome = await seal(journal)
        status = .idle
        lastNote = Self.sentence(for: outcome, reason: .interrupted)
        refreshUnsealed()
        return outcome
    }

    private var sealing = false

    /// Transcribes a stopped recording, puts its timeline together and seals the bundle. The
    /// recorded parts are removed only once the bundle is sealed; on any failure they stay.
    @discardableResult
    private func seal(_ journal: JobRecordingCaptureStore.Journal) async -> Outcome {
        sealing = true
        defer { sealing = false }
        let sessionID = journal.sessionID
        // Only parts that are really there. The timeline and the manifest must name the same ones.
        let parts = journal.parts.filter {
            JobRecordingCaptureStore.size(of: seams.capture.partFile(sessionID: sessionID, partID: $0.partID)) > 0
        }
        guard !parts.isEmpty else {
            seams.capture.remove(sessionID: sessionID)
            return .nothingRecorded
        }
        // Nothing is sealed, and nothing signed, on a pairing that does not verify now.
        guard let binding = await seams.binding() else { return .waitingToPrepare }

        var words: [RecordedJobAssembly.PartWords] = []
        for part in parts where part.audio != nil {
            let file = seams.capture.partFile(sessionID: sessionID, partID: part.partID)
            words.append(.init(partID: part.partID, utterances: await seams.transcribe(file)))
        }
        let assembled = RecordedJobAssembly.assemble(
            clock: SessionClock(wallStart: journal.wallStart, monotonicStart: 0), parts: parts,
            noted: journal.noted.compactMap(\.event), log: seams.logEntries(sessionID), words: words,
            endedAt: journal.stoppedAt ?? .zero)
        do {
            let input = JobRecordingBundleStore.SealInput(
                bundleID: seams.newBundleID(), sessionID: sessionID,
                jobNumber: BundleManifest.writableJobNumber(journal.jobNumber), binding: binding,
                consentAt: journal.consentAt,
                // Nothing here blurs. A recording is only made where the organisation does not
                // require it, and an unblurred bundle is never sent where it does.
                blurred: false, droppedFrames: 0,
                timeline: try assembled.timeline.encoded(), transcript: try assembled.transcript.encoded(),
                parts: parts.map { part in
                    .init(partID: part.partID, track: part.video != nil ? .video : .audio, container: "mp4",
                          file: seams.capture.partFile(sessionID: sessionID, partID: part.partID))
                })
            let record = try await seams.bundles.seal(input, now: seams.wallNow(), sign: seams.sign)
            seams.capture.remove(sessionID: sessionID)
            seams.log(sessionID, .recordingBundleSealed, [
                "manifest_sha256": AnyCodable(record.manifestSHA256),
                "chunks": AnyCodable(record.chunks.count),
                "bytes": AnyCodable(Int(record.totalBytes)),
                "parts": AnyCodable(parts.count),
                "utterances": AnyCodable(assembled.transcript.utterances.count),
            ])
            seams.sealed()
            return .sealed(bundleID: record.bundleID)
        } catch {
            return .waitingToPrepare
        }
    }

    private func releaseClaimedStream() async {
        guard holdsStreamClaim else { return }
        holdsStreamClaim = false
        await seams.releaseStream()
    }
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
