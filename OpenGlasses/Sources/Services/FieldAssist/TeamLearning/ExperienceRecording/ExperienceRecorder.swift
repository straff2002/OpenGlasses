import Foundation

/// Hears a recording and transcribes it on the phone (Plan IM P1). The live one is
/// `LiveExperienceCapture`; a test hands the recorder a script.
@MainActor
protocol ExperienceCapture: AnyObject {
    /// Why it cannot record right now, in a sentence, or nil when it can. Asked before the first
    /// case of a session; the live capture asks for speech and microphone access here and refuses
    /// when the phone cannot transcribe its language without the internet.
    func prepare() async -> String?

    /// Start recording to `url` and transcribing. Each stretch of speech — what was said between
    /// pauses — is handed to `onStretch`; a failure that ends the capture goes to `onFailure`.
    func start(writingTo url: URL,
               onStretch: @escaping @MainActor (String) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws

    /// Stop. Returns whether the file holds audio, and the stretch still being heard when it
    /// stopped. Nothing reaches `onStretch` after this is called.
    func stop() async -> ExperienceCaptureEnding

    /// The language the capture transcribes in: the recorder listens for its markers, and English's
    /// (`ExperienceRecordingMarkers.Listening.language`), and the car reads its phrases.
    var recognitionLocale: Locale { get }
}

extension ExperienceCapture {
    /// A capture that does not say transcribes in English.
    var recognitionLocale: Locale { Locale(identifier: "en-US") }
}

struct ExperienceCaptureEnding: Equatable, Sendable {
    var audioWritten: Bool
    var lastStretch: String?
}

/// Filing a recording made during an open job (Plan IM P1): today's path, a `spoken` candidate
/// on the job through `LearningCandidateService.note`, never a recollection.
enum ExperienceJobFiling {

    enum Outcome: Equatable {
        /// `count` candidates filed: one, or a long recording in parts.
        case filed(count: Int, jobReference: String?)
        /// Nothing filed; the sentence says why.
        case refused(String)
    }

    /// Every part is checked against the candidate's rules before any is filed, so a recording is
    /// filed whole or not at all.
    @MainActor
    static func file(_ transcript: String, with service: LearningCandidateService) -> Outcome {
        let parts = ExperienceTranscript.findingParts(transcript)
        guard !parts.isEmpty else { return .refused(LearningCandidateText.Refusal.missingFinding.spoken) }
        if let refusal = service.entitlementRefusal() { return .refused(refusal.spoken) }
        for part in parts {
            if case .failure(let refusal) = LearningCandidateText.clean(finding: part, symptom: nil, fix: nil) {
                return .refused(refusal.spoken)
            }
        }
        var filed: [LearningCandidate] = []
        for part in parts {
            switch service.note(finding: part) {
            case .success(let candidate): filed.append(candidate)
            case .failure(let refusal):
                if filed.isEmpty { return .refused(refusal.spoken) }
            }
        }
        return .filed(count: filed.count, jobReference: filed.first?.jobReference)
    }
}

/// "Record experience" (Plan IM P1): the recorder on the phone and in the car.
///
/// FO §6's debrief, without the model: the technician talks, the phone listens and transcribes on
/// the device, and a spoken marker or a button ends the case. **Nothing said reaches the
/// assistant**: the recorder never logs a turn, never builds a prompt, and starts only when no
/// conversation is listening. What it keeps depends on where the technician is:
///
/// - **No job open** — an `ExperienceRecording` in its own store, with its audio for 30 days
///   (decision 2). Nothing leaves the phone in P1.
/// - **A job open** — a `spoken` candidate on that job, exactly as "note this for the team" files
///   one (`ExperienceJobFiling`); the audio is not kept. A job that closes mid-recording is not the
///   job any more, and the recording is kept on the phone instead.
///
/// One case per recording: "that's one, next case" ends one and starts the next
/// (`ExperienceRecordingMarkers`), "that's all" or Stop ends the session, and ten minutes ends a
/// recording whatever is being said. The standing line — no customer names or addresses — is said
/// once per session; in the car the five prompts are read aloud as well.
///
/// **A site recording** (Plan IM P4, "Tell me about this site") is the same session of a different
/// kind: in the car the site prompts are read instead, and it is always kept on the phone, never
/// filed on an open job, because a site recording drafts a site document and never a learning.
@MainActor
final class ExperienceRecorder: ObservableObject {

    enum Surface: String, Equatable, Sendable {
        case phone
        case carPlay
    }

    enum Phase: Equatable {
        case idle
        /// Saying the standing line (and, in the car, the prompts) before the first case.
        case preparing
        /// Recording case `caseNumber` of the session. `jobSessionId` is the job open when it
        /// began, or nil.
        case recording(caseNumber: Int, startedAt: Date, jobSessionId: String?)
        /// Ending a case: the capture is stopping and what was said is being kept.
        case saving

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
        var isBusy: Bool { self != .idle }
    }

    /// What became of the last case.
    enum Outcome: Equatable {
        case kept(recordingId: String)
        case filedOnJob(count: Int, jobReference: String?)
        /// Filing on the job was refused; the recording was kept on the phone instead.
        case keptAfterRefusal(recordingId: String, reason: String)
        case nothingHeard
        /// Not started: the sentence says why.
        case refused(String)

        var spoken: String {
            switch self {
            case .kept: return ExperienceRecorderCopy.keptOnPhone
            case .filedOnJob(let count, let reference):
                return ExperienceRecorderCopy.filedOnJob(count: count, jobReference: reference)
            case .keptAfterRefusal(_, let reason): return reason + " " + ExperienceRecorderCopy.keptInstead
            case .nothingHeard: return ExperienceRecorderCopy.nothingHeard
            case .refused(let reason): return reason
            }
        }
    }

    /// Why a case ended.
    enum Ending: Equatable {
        case nextCase(opening: String)
        case finish
        case capReached
        case failed(String)
    }

    struct Seams {
        var availability: @MainActor () -> ExperienceRecordingAvailability.Verdict
        /// Whether a conversation is listening, which would hear the recording too.
        var conversationActive: @MainActor () -> Bool
        var speak: @MainActor (String) async -> Void
        var makeCapture: @MainActor () -> any ExperienceCapture
        /// Where a recording is written while it is being made.
        var captureFolder: () -> URL
        /// The open job, if one is.
        var openJob: @MainActor () -> String?
        var fileOnJob: @MainActor (String) -> ExperienceJobFiling.Outcome
        /// The vault a new job would start on.
        var vaultInForce: @MainActor () -> String
        var now: () -> Date
        /// Call `tick(now:)` about once a second until the returned closure is called.
        var startTicker: @MainActor (ExperienceRecorder) -> () -> Void
    }

    let store: ExperienceRecordingStore
    private let seams: Seams

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var surface: Surface = .phone
    /// What the session records: cases, or a site.
    @Published private(set) var kind: ExperienceRecording.Kind = .experience
    /// Seconds into the case being recorded.
    @Published private(set) var elapsed: TimeInterval = 0
    /// What has been heard of the case so far, cleaned and redacted as it will be kept.
    @Published private(set) var heardSoFar = ""
    @Published private(set) var lastOutcome: Outcome?

    private var capture: (any ExperienceCapture)?
    /// The markers the capture's language says, and English's.
    private var listening: ExperienceRecordingMarkers.Listening = .english
    private var stretches: [String] = []
    private var caseId = ""
    private var caseURL: URL?
    private var caseCount = 0
    private var ending = false
    private var stopTicker: (() -> Void)?
    private var standingLineSaid = false
    /// Stop was pressed while a case was being saved: the next case is not started.
    private var stopRequested = false

    init(store: ExperienceRecordingStore, seams: Seams) {
        self.store = store
        self.seams = seams
    }

    /// Whether the recorder is offered on the surfaces, right now.
    var verdict: ExperienceRecordingAvailability.Verdict { seams.availability() }

    // MARK: - Starting and stopping

    /// Start a session: the standing line, the prompts in the car, then the first case.
    func start(from surface: Surface, kind: ExperienceRecording.Kind = .experience) async {
        guard phase == .idle else { return }
        let verdict = seams.availability()
        guard verdict.isAvailable else {
            await refuse(verdict.refusal ?? ExperienceRecordingAvailability.Verdict.notOffered.refusal ?? "")
            return
        }
        guard !seams.conversationActive() else {
            await refuse(ExperienceRecorderCopy.conversationActive)
            return
        }
        self.surface = surface
        self.kind = kind
        phase = .preparing
        lastOutcome = nil
        caseCount = 0
        stopRequested = false
        let probe = seams.makeCapture()
        if let reason = await probe.prepare() {
            phase = .idle
            await refuse(reason)
            return
        }
        var intro: [String] = []
        if !standingLineSaid {
            intro.append(ExperienceRecorderCopy.standingLine)
            standingLineSaid = true
        }
        if surface == .carPlay {
            intro.append(kind == .site ? ExperienceRecorderCopy.carPlaySitePrompts
                         : ExperienceRecorderCopy.carPlayPrompts(speaking: probe.recognitionLocale))
        }
        intro.append(ExperienceRecorderCopy.recordingNow)
        await seams.speak(intro.joined(separator: " "))
        // Stopped while the prompts were being read: nothing was recorded.
        guard phase == .preparing else { return }
        beginCase(opening: nil, capture: probe)
    }

    /// The Stop button, on the phone or the car's row. Ends the case and the session.
    func finish() async {
        switch phase {
        case .preparing:
            endSession()
        case .recording:
            await endCase(.finish)
        case .saving:
            stopRequested = true
        case .idle:
            return
        }
    }

    /// The recorder's clock: the elapsed time, and the ten-minute cap.
    func tick(now: Date) async {
        guard case .recording(_, let startedAt, _) = phase, !ending else { return }
        elapsed = max(0, now.timeIntervalSince(startedAt))
        if ExperienceRecorderRules.capReached(startedAt: startedAt, now: now) {
            await endCase(.capReached)
        }
    }

    /// A stretch of speech from the capture: part of the case, or a marker that ends it.
    func heard(_ stretch: String) async {
        guard phase.isRecording else { return }
        if ending {
            // Late words while the case is ending belong to it; a marker in them changes nothing.
            stretches.append(stretch)
            return
        }
        let split = ExperienceRecordingMarkers.split(stretch, listening: listening)
        if !split.before.isEmpty {
            stretches.append(split.before)
            heardSoFar = ExperienceTranscript.clean(stretches.joined(separator: " ")).text
        }
        switch split.marker {
        case .none: return
        case .nextCase: await endCase(.nextCase(opening: split.after))
        case .finish: await endCase(.finish)
        }
    }

    // MARK: - A case

    private func beginCase(opening: String?, capture provided: (any ExperienceCapture)? = nil) {
        let capture = provided ?? seams.makeCapture()
        caseId = ExperienceRecording.newID()
        let folder = seams.captureFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(caseId).m4a")
        let startedAt = Date(timeIntervalSince1970: seams.now().timeIntervalSince1970.rounded(.down))
        do {
            try capture.start(
                writingTo: url,
                onStretch: { [weak self] text in Task { await self?.heard(text) } },
                onFailure: { [weak self] reason in Task { await self?.endCase(.failed(reason)) } })
        } catch {
            try? FileManager.default.removeItem(at: url)
            PrivacyLog.audio(.recording, .engineStartFailed, owner: PrivacyToken("experience"),
                             error: SafeErrorSummary(error))
            endSession()
            Task { await self.refuse(String(localized: "The microphone couldn't start, so nothing was recorded.")) }
            return
        }
        self.capture = capture
        listening = .language(capture.recognitionLocale)
        caseURL = url
        caseCount += 1
        stretches = opening.map { $0.isEmpty ? [] : [$0] } ?? []
        heardSoFar = stretches.isEmpty ? "" : ExperienceTranscript.clean(stretches.joined(separator: " ")).text
        elapsed = 0
        ending = false
        phase = .recording(caseNumber: caseCount, startedAt: startedAt, jobSessionId: seams.openJob())
        stopTicker = seams.startTicker(self)
        PrivacyLog.audio(.recording, .captureStarted, owner: PrivacyToken("experience"), count: caseCount)
    }

    private func endCase(_ why: Ending) async {
        guard case .recording(_, let startedAt, let jobSessionId) = phase, !ending,
              let capture else { return }
        ending = true
        stopTicker?()
        stopTicker = nil
        let ended = await capture.stop()
        self.capture = nil
        phase = .saving
        if let last = ended.lastStretch {
            let split = ExperienceRecordingMarkers.split(last, listening: listening)
            if !split.before.isEmpty { stretches.append(split.before) }
        }
        let cleaned = ExperienceTranscript.clean(stretches.joined(separator: " "))
        let seconds = Int(min(ExperienceRecorderRules.recordingCap,
                              max(0, seams.now().timeIntervalSince(startedAt))).rounded(.down))
        let url = caseURL
        stretches = []
        heardSoFar = ""
        caseURL = nil

        let outcome: Outcome
        if cleaned.text.isEmpty {
            outcome = .nothingHeard
            if let url { try? FileManager.default.removeItem(at: url) }
        } else if kind == .experience, let job = jobSessionId, seams.openJob() == job {
            switch seams.fileOnJob(cleaned.text) {
            case .filed(let count, let reference):
                outcome = .filedOnJob(count: count, jobReference: reference)
                // The candidate is the record on a job; its audio is not kept.
                if let url { try? FileManager.default.removeItem(at: url) }
            case .refused(let reason):
                keep(cleaned, startedAt: startedAt, seconds: seconds, audio: ended.audioWritten ? url : nil)
                outcome = .keptAfterRefusal(recordingId: caseId, reason: reason)
            }
        } else {
            keep(cleaned, startedAt: startedAt, seconds: seconds, audio: ended.audioWritten ? url : nil)
            outcome = .kept(recordingId: caseId)
        }
        if !ended.audioWritten, let url { try? FileManager.default.removeItem(at: url) }
        lastOutcome = outcome
        PrivacyLog.audio(.recording, .engineStopped, owner: PrivacyToken("experience"),
                         detail: PrivacyToken(Self.token(for: outcome)), milliseconds: seconds * 1000)

        switch why {
        case .nextCase(let opening):
            ending = false
            guard !stopRequested else {
                endSession()
                await seams.speak(outcome.spoken)
                return
            }
            await seams.speak(outcome.spoken + " " + ExperienceRecorderCopy.nextCase)
            guard phase == .saving else { return }
            guard !stopRequested else {
                endSession()
                return
            }
            beginCase(opening: opening)
        case .finish:
            endSession()
            await seams.speak(outcome.spoken)
        case .capReached:
            endSession()
            await seams.speak(ExperienceRecorderCopy.capReached + " " + outcome.spoken)
        case .failed(let reason):
            endSession()
            await seams.speak(reason + " " + outcome.spoken)
        }
    }

    private func keep(_ cleaned: ExperienceTranscript.Cleaned, startedAt: Date, seconds: Int, audio: URL?) {
        let recording = ExperienceRecording(id: caseId, kind: kind, createdAt: startedAt, duration: seconds,
                                            transcript: cleaned.text, redactions: cleaned.redactions,
                                            vaultId: seams.vaultInForce())
        store.add(recording, audioFrom: audio)
    }

    private func endSession() {
        stopTicker?()
        stopTicker = nil
        capture = nil
        ending = false
        elapsed = 0
        heardSoFar = ""
        stretches = []
        phase = .idle
        stopRequested = false
        // The next session says the standing line again.
        standingLineSaid = false
    }

    private func refuse(_ reason: String) async {
        lastOutcome = .refused(reason)
        await seams.speak(reason)
    }

    private static func token(for outcome: Outcome) -> String {
        switch outcome {
        case .kept: return "kept"
        case .filedOnJob: return "filedOnJob"
        case .keptAfterRefusal: return "keptAfterRefusal"
        case .nothingHeard: return "nothingHeard"
        case .refused: return "refused"
        }
    }
}

extension ExperienceRecorderRules {
    /// Whether a recording begun at `startedAt` has reached the ten-minute cap by `now`.
    static func capReached(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= recordingCap
    }

    /// Where a recording is written while it is being made: the app's temporary folder, which is
    /// never backed up. The store moves a kept recording's audio out of it.
    static func captureFolder(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("ExperienceRecordingCapture", isDirectory: true)
    }
}
