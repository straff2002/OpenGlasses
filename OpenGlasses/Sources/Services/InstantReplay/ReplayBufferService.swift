import Combine
import Foundation
import QuartzCore
import UIKit

/// Instant Replay — a short rolling buffer of what the glasses camera already showed, kept only
/// while the camera is streaming for something else, so "keep the last 30 seconds" can save a
/// moment that has just happened.
///
/// # Where the pixels come from
///
/// `OutboundFrameRelay.publisher` and nothing else (`OutboundFrameConsumer.instantReplayBuffer`).
/// The relay is where the bystander blur runs, once, for every camera-rate consumer: with the blur
/// on, the buffer holds blurred frames and a saved clip is blurred. If the blur is required and
/// cannot run, the relay delivers nothing and the buffer simply has a gap — it is never fed raw
/// frames instead. The publisher arrives as an argument, so this type never has to know that
/// `CameraService` exists. Buffering the glasses' compressed stream before decode would be cheaper
/// and is rejected: those are pixels before the blur.
///
/// # When it exists
///
/// Only while `ReplayBufferPolicy` says so — the setting on, the glasses camera already streaming,
/// Medical Compliance off, a normal power posture, room on the disk. It never starts, keeps alive
/// or restarts the camera. The moment a condition stops holding, every segment is deleted. It is
/// also deleted at launch (leftovers of a crash), by a subject erasure, and when the setting goes
/// off.
///
/// # Audio: none
///
/// Video only, for the job clip's reason: a clip kept from the last thirty seconds is of a moment
/// nobody agreed to record, and the voices in it have no equivalent of the face blur. The glasses'
/// own camera audio is an experimental SDK interface and is never used.
///
/// # On disk
///
/// Two-second H.264 segments, each starting on a keyframe, in `Application Support/InstantReplay`:
/// `completeUnlessOpen` (a segment can still be written while the phone locks mid-stream) and
/// excluded from backup. A save joins the segments that cover the asked span and exports them
/// passthrough, with no re-encode; segments are never moved, only read.
@MainActor
final class ReplayBufferService: ObservableObject {

    // MARK: - Published state

    /// What the buffer is doing and, when off, why. The status mark and the settings row read it.
    @Published private(set) var decision: ReplayBufferPolicy.Decision = .off(.settingOff)
    /// Seconds of continuous video held right now.
    @Published private(set) var bufferedSeconds: TimeInterval = 0
    /// A save is being put together.
    @Published private(set) var isSaving = false

    var isRunning: Bool { decision.isRunning }

    // MARK: - Seams

    /// Everything device-facing, injected, so every stop condition, the rotation, the eviction and
    /// what a save files where are exercisable with no camera, no encoder and no job.
    struct Seams {
        var settingOn: () -> Bool = { Config.instantReplayEnabled }
        var orgPinnedOff: () -> Bool = { PolicyEnvelope.isLocked(.instantReplayEnabled) }
        var medicalCompliance: () -> Bool = { Config.hipaaMode }
        /// The glasses camera is streaming. Read, never requested.
        var glassesStreaming: () -> Bool = { false }
        var posture: () -> PowerPosture = { .normal }
        var freeBytes: () -> Int64? = { ReplayBufferService.freeDiskBytes() }
        var bufferSeconds: () -> TimeInterval = { Config.instantReplayBufferSeconds }
        var frameRate: () -> Int = { Config.cameraFrameRate }
        var resolution: () -> String = { Config.cameraResolution }
        /// The app-wide blur switch, recorded per segment.
        var filterEnabled: () -> Bool = { Config.privacyFilterEnabled }
        /// The relay's running drop counter, read at each segment's start and end.
        var droppedFrameCount: () -> Int = { 0 }
        /// Seconds on the host clock — the same clock for frames, segments and "the last 30
        /// seconds".
        var now: () -> TimeInterval = { CACurrentMediaTime() }
        /// The wall clock a kept recording is named by.
        var wallClock: () -> Date = { Date() }
        var directory: URL = ReplayBufferService.defaultDirectory
        var makeWriter: @MainActor (URL, CGSize, Int) throws -> any ReplaySegmentWriting = { url, size, rate in
            try AVReplaySegmentWriter(url: url, size: size, frameRate: rate)
        }
        var composer: any ReplayClipComposing = AVReplayClipComposer()
        /// Where a composed clip is written before it is filed.
        var scratchDirectory: () -> URL = { FileManager.default.temporaryDirectory }
        var recordingsDirectory: () -> URL = { RecordingFiler.defaultRecordingsDirectory }
        /// The open job, if any. Asked at save time only.
        var jobs: @MainActor () -> (any JobClipFiling)? = { nil }
        var jobClipMaximum: () -> TimeInterval = { Config.jobClipMaximumSeconds }
        /// Add a filed recording to the Photos library. Only ever called for a save that named
        /// Photos. Returns whether it landed.
        var saveToPhotos: @MainActor (URL) async -> Bool = { _ in false }
        /// Ticks while the buffer runs, so a condition that changes without an event (Medical
        /// Compliance, the organisation pin, free space) still stops it within a second.
        var startsTicker: Bool = true
    }

    private var seams: Seams
    private var source: PassthroughSubject<UIImage, Never>?

    init(seams: Seams = Seams()) {
        self.seams = seams
        self.ring = ReplaySegmentRing(capacity: 1)
    }

    /// Wire the app's services and the **blurred relay** in. `source` must be
    /// `OutboundFrameRelay.publisher` — `OutboundFrameConsumerTests` reads the call site.
    func connect(_ seams: Seams, source: PassthroughSubject<UIImage, Never>) {
        if isRunning { end(.settingOff) }
        self.seams = seams
        self.source = source
        reconcile()
    }

    // MARK: - Lifecycle

    /// The decision as of now, with the plan worked from the delivered frame size once a frame has
    /// said what it is.
    func currentDecision() -> ReplayBufferPolicy.Decision {
        let bufferSeconds = seams.bufferSeconds()
        let plan: ReplayBufferPlan
        if let deliveredSize {
            plan = ReplayBufferPlan(bufferSeconds: bufferSeconds, width: Int(deliveredSize.width),
                                    height: Int(deliveredSize.height), frameRate: seams.frameRate())
        } else {
            plan = .estimate(bufferSeconds: bufferSeconds, resolution: seams.resolution(),
                             frameRate: seams.frameRate())
        }
        return ReplayBufferPolicy.decide(.init(
            settingOn: seams.settingOn(), orgPinnedOff: seams.orgPinnedOff(),
            glassesStreaming: seams.glassesStreaming(), medicalCompliance: seams.medicalCompliance(),
            posture: seams.posture(), freeBytes: seams.freeBytes(), plan: plan))
    }

    /// Re-read every condition and start or stop the buffer to match. Cheap; safe to call often.
    func reconcile() {
        discardIfBlurTurnedOn()
        let next = currentDecision()
        switch (decision, next) {
        case (.run(let running), .run(let wanted)):
            if running.bufferSeconds != wanted.bufferSeconds {
                // A new length is a new buffer: simpler and more honest than re-cutting the old
                // one, and the wearer has just touched the setting.
                end(nil)
                begin(wanted)
            }
        case (.off, .run(let wanted)):
            begin(wanted)
        case (.run, .off(let reason)):
            end(reason)
        case (.off, .off):
            break
        }
        if next != decision { decision = next }
    }

    private func begin(_ plan: ReplayBufferPlan) {
        guard let source else { return }
        blurWasOn = seams.filterEnabled()
        generation += 1
        ring = ReplaySegmentRing(capacity: plan.capacity)
        bufferedSeconds = 0
        Self.prepareDirectory(seams.directory)
        subscription = source.sink { [weak self] image in self?.ingest(image) }
        if seams.startsTicker {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
        }
        PrivacyLog.recording(.replayBufferStarted, width: plan.width, height: plan.height,
                             frameRate: plan.frameRate, seconds: plan.bufferSeconds)
    }

    /// Stop and delete everything. `reason` nil is a restart, not worth a log line of its own.
    private func end(_ reason: ReplayOffReason?) {
        subscription?.cancel()
        subscription = nil
        ticker?.invalidate()
        ticker = nil
        generation += 1
        current?.writer.cancel()
        current = nil
        deliveredSize = nil
        writerRetryAfter = nil
        wipeEverything()
        if let reason {
            PrivacyLog.recording(.replayBufferStopped, detail: PrivacyToken(reason.rawValue))
        }
    }

    // MARK: - Frames

    private var subscription: AnyCancellable?
    private var ticker: Timer?
    private(set) var ring: ReplaySegmentRing
    /// Bumped by every start and stop, so a segment finishing after the buffer it belonged to has
    /// gone is deleted rather than filed into the next one.
    private var generation = 0
    private var sequence = 0
    private var deliveredSize: CGSize?
    /// After a writer could not be made, wait a segment before trying again rather than failing
    /// once a frame.
    private var writerRetryAfter: TimeInterval?

    private struct OpenSegment {
        let fileName: String
        let url: URL
        let writer: any ReplaySegmentWriting
        let size: CGSize
        let startedAt: TimeInterval
        var lastFrameAt: TimeInterval
        var frames: Int
        let droppedAtStart: Int
        var filterStayedOn: Bool
        let generation: Int
    }

    private var current: OpenSegment?
    private var closing: [Task<Void, Never>] = []

    /// One frame off the relay.
    ///
    /// Not private: the rotation, the size-change boundary and the writer-failure backoff are the
    /// whole behaviour, and a test drives them with frames of its own making.
    func ingest(_ image: UIImage) {
        guard isRunning, let size = Self.encodeSize(of: image) else { return }
        discardIfBlurTurnedOn()
        let now = seams.now()
        if deliveredSize != size {
            deliveredSize = size
            // The plan's size line follows what is really delivered.
            let next = currentDecision()
            if next != decision, next.isRunning { decision = next }
        }
        if let open = current,
           open.size != size || now - open.startedAt >= ReplayBufferPlan.segmentSeconds {
            closeCurrentSegment()
        }
        if current == nil {
            if let retry = writerRetryAfter, now < retry { return }
            guard openSegment(size: size, at: now) else { return }
        }
        guard var open = current else { return }
        open.writer.append(image, at: now - open.startedAt)
        open.frames += 1
        open.lastFrameAt = now
        if open.filterStayedOn, !seams.filterEnabled() { open.filterStayedOn = false }
        current = open
    }

    private func openSegment(size: CGSize, at now: TimeInterval) -> Bool {
        sequence += 1
        let name = String(format: "segment-%06d.mp4", sequence)
        let url = seams.directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: seams.directory.path) {
            Self.prepareDirectory(seams.directory)
        }
        try? FileManager.default.removeItem(at: url)
        do {
            let writer = try seams.makeWriter(url, size, seams.frameRate())
            current = OpenSegment(fileName: name, url: url, writer: writer, size: size,
                                  startedAt: now, lastFrameAt: now, frames: 0,
                                  droppedAtStart: seams.droppedFrameCount(),
                                  filterStayedOn: seams.filterEnabled(), generation: generation)
            writerRetryAfter = nil
            return true
        } catch {
            writerRetryAfter = now + ReplayBufferPlan.segmentSeconds
            PrivacyLog.recording(.replaySegmentFailed, detail: PrivacyToken("writerUnavailable"),
                                 error: SafeErrorSummary(error))
            return false
        }
    }

    /// Finish the segment being written, in the background. The ring learns of it when its file
    /// is complete.
    private func closeCurrentSegment() {
        guard let open = current else { return }
        current = nil
        let droppedAtEnd = seams.droppedFrameCount()
        let task = Task { @MainActor [weak self] in
            let wrote = await open.writer.finish()
            self?.segmentFinished(open, wrote: wrote, droppedAtEnd: droppedAtEnd)
        }
        closing.append(task)
    }

    private func segmentFinished(_ open: OpenSegment, wrote: Bool, droppedAtEnd: Int) {
        guard wrote, open.frames > 0, open.generation == generation, isRunning else {
            try? FileManager.default.removeItem(at: open.url)
            if !wrote {
                PrivacyLog.recording(.replaySegmentFailed, count: open.frames,
                                     detail: PrivacyToken("finishFailed"))
            }
            return
        }
        Self.protect(open.url)
        let segment = ReplaySegment(fileName: open.fileName, firstFrameAt: open.startedAt,
                                    lastFrameAt: open.lastFrameAt, frameCount: open.frames,
                                    width: Int(open.size.width), height: Int(open.size.height),
                                    hadDroppedFrames: droppedAtEnd > open.droppedAtStart,
                                    filterWasOn: open.filterStayedOn)
        for evicted in ring.append(segment) { delete(evicted.fileName) }
        bufferedSeconds = ring.continuousSeconds
    }

    /// Wait for every segment being finished to land in the ring.
    func settle() async {
        while !closing.isEmpty {
            let pending = closing
            closing = []
            for task in pending { await task.value }
        }
    }

    /// Close the segment being written now, so a save includes the last moment, and wait for it.
    func rollSegment() async {
        closeCurrentSegment()
        await settle()
    }

    // MARK: - The blur switched on (review follow-up 2026-11-10)

    /// The blur switch as last seen while the buffer ran.
    private var blurWasOn: Bool?

    /// Bystander blur went from off to on: everything buffered before that moment held faces the
    /// wearer has now said to blur, so it goes — the segment being written, the ones finishing and
    /// the ring — and the buffer carries on from nothing, the same rule as a new length. Read on
    /// every frame, on the one-second tick and at save time, so a save straight after the switch
    /// never reaches footage from before it.
    private func discardIfBlurTurnedOn() {
        let on = seams.filterEnabled()
        defer { blurWasOn = on }
        guard isRunning, blurWasOn == false, on else { return }
        let discarded = discardBuffered()
        PrivacyLog.recording(.replayBufferStopped, count: discarded, detail: PrivacyToken("blurTurnedOn"))
    }

    /// Cancel the open segment, drop any still finishing, and delete the ring. Returns how many
    /// finished segments went.
    private func discardBuffered() -> Int {
        let held = ring.count
        current?.writer.cancel()
        current = nil
        generation += 1
        wipeEverything()
        return held
    }

    // MARK: - Files

    /// Files a save is reading. Evicted while pinned, they are deleted when the save ends.
    private var pinned: Set<String> = []
    private var deferredDeletes: Set<String> = []
    private var wipeAfterSave = false

    private func delete(_ fileName: String) {
        if pinned.contains(fileName) {
            deferredDeletes.insert(fileName)
            return
        }
        try? FileManager.default.removeItem(at: seams.directory.appendingPathComponent(fileName))
    }

    private func wipeEverything() {
        for segment in ring.removeAll() { delete(segment.fileName) }
        bufferedSeconds = 0
        if pinned.isEmpty {
            Self.removeAll(in: seams.directory)
        } else {
            wipeAfterSave = true
        }
    }

    /// Delete every segment. The buffer keeps running if it was — from nothing. Returns how many
    /// segments went. This is the store's delete-all and its subject erasure: a segment is not
    /// indexed by who appears in it, so forgetting a person forgets the whole buffer.
    @discardableResult
    func deleteAll() -> Int {
        discardBuffered()
    }

    // MARK: - Saving

    /// Keep part of the buffer. Never starts the camera; refuses, in words, when there is nothing
    /// to keep or nowhere to put it.
    func save(_ request: ReplaySaveRequest) async -> ReplaySaveOutcome {
        reconcile()
        let jobs = request.destination == .job ? seams.jobs() : nil
        let decision = ReplaySaveDecision.decide(request, buffer: self.decision,
                                                 jobOpen: jobs?.isOpenForEvidence ?? false,
                                                 jobClipMaximum: seams.jobClipMaximum())
        guard case .save(let seconds, let destination, let capped) = decision else {
            if case .refuse(let refusal) = decision { return .init(result: .refused(refusal)) }
            return .init(result: .refused(.couldNotSave))
        }
        guard !isSaving else { return .init(result: .refused(.couldNotSave)) }
        isSaving = true
        defer { isSaving = false }

        await rollSegment()
        // The blur may have come on while the last segment closed.
        discardIfBlurTurnedOn()
        guard let span = ring.span(coveringLast: seconds, now: seams.now()) else {
            return .init(result: .refused(.nothingBuffered))
        }
        // Everything that erases the buffer — a delete-all, a subject erasure, the buffer ending,
        // the blur coming on — bumps the generation. A clip composed from footage erased while it
        // was being read is not filed anywhere (review follow-up 2026-11-10).
        let startedIn = generation

        let names = span.segments.map(\.fileName)
        pinned.formUnion(names)
        defer { releasePins(names) }

        let output = seams.scratchDirectory()
            .appendingPathComponent("replay-\(UUID().uuidString).mp4")
        let duration: TimeInterval
        do {
            duration = try await seams.composer.compose(
                names.map { seams.directory.appendingPathComponent($0) }, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            PrivacyLog.recording(.replaySaveFailed, detail: PrivacyToken("composeFailed"),
                                 error: SafeErrorSummary(error))
            return .init(result: .refused(.couldNotSave))
        }
        discardIfBlurTurnedOn()
        guard generation == startedIn, isRunning else {
            try? FileManager.default.removeItem(at: output)
            PrivacyLog.recording(.replaySaveFailed, detail: PrivacyToken("erasedWhileSaving"))
            if case .off(let reason) = self.decision { return .init(result: .refused(.notRunning(reason))) }
            return .init(result: .refused(.nothingBuffered))
        }
        // The file's own length is what was kept: a 30-second ask normally yields 30–32, because
        // the cut lands on a segment's keyframe.
        let kept = duration
        let short = ReplaySaveOutcome.isShort(kept: kept, asked: seconds)

        switch destination {
        case .recordings, .photos:
            let filer = RecordingFiler(recordingsDirectory: seams.recordingsDirectory())
            let filed = filer.file(output, date: seams.wallClock(), saveToPhotos: destination == .photos,
                                   prefix: RecordingFiler.replayPrefix)
            guard filed.savedToLibrary else {
                try? FileManager.default.removeItem(at: output)
                PrivacyLog.recording(.replaySaveFailed, detail: PrivacyToken("fileFailed"))
                return .init(result: .refused(.couldNotSave))
            }
            var photosLanded: Bool?
            if destination == .photos {
                photosLanded = await seams.saveToPhotos(filed.primaryURL)
            }
            PrivacyLog.recording(.replaySaved, seconds: kept, success: photosLanded,
                                 detail: PrivacyToken(destination.rawValue))
            return .init(result: .saved(destination: destination, askedSeconds: seconds,
                                        keptSeconds: kept, cappedForJob: false,
                                        photosLanded: photosLanded))
        case .job:
            defer { try? FileManager.default.removeItem(at: output) }
            guard let jobs, let data = try? Data(contentsOf: output), !data.isEmpty else {
                return .init(result: .refused(.couldNotSave))
            }
            let poster = await seams.composer.posterJPEG(of: output)
            guard jobs.attachClip(data, posterJPEG: poster, caption: request.caption,
                                  durationSeconds: kept, filterWasOn: span.filterWasOn,
                                  cutShort: short) != nil else {
                PrivacyLog.recording(.replaySaveFailed, detail: PrivacyToken("jobRefused"))
                return .init(result: .refused(.couldNotSave))
            }
            PrivacyLog.recording(.replaySaved, seconds: kept, detail: PrivacyToken("job"))
            return .init(result: .saved(destination: .job, askedSeconds: seconds, keptSeconds: kept,
                                        cappedForJob: capped, photosLanded: nil))
        }
    }

    private func releasePins(_ names: [String]) {
        pinned.subtract(names)
        let due = deferredDeletes.subtracting(pinned)
        deferredDeletes.subtract(due)
        for name in due { delete(name) }
        if wipeAfterSave, pinned.isEmpty {
            wipeAfterSave = false
            if !isRunning { Self.removeAll(in: seams.directory) }
        }
    }

    // MARK: - Status

    /// "Instant Replay is keeping the last 48 seconds." — or why it isn't running.
    var statusLine: String {
        switch decision {
        case .off(let reason):
            return reason.spoken
        case .run(let plan):
            let held = Int(bufferedSeconds.rounded())
            if held < 1 { return "Instant Replay is on and just getting started." }
            let length = ReplaySaveOutcome.length(min(bufferedSeconds, plan.bufferSeconds))
            return "Instant Replay is keeping the last \(length), up to "
                + "\(ReplaySaveOutcome.length(plan.bufferSeconds))."
        }
    }

    // MARK: - Pure helpers

    /// H.264 needs even dimensions, encoded at the size the frames really arrive in.
    nonisolated static func encodeSize(of image: UIImage) -> CGSize? {
        guard let cgImage = image.cgImage else { return nil }
        return CGSize(width: max(2, (cgImage.width / 2) * 2), height: max(2, (cgImage.height / 2) * 2))
    }

    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("InstantReplay", isDirectory: true)
    }

    nonisolated static func freeDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The buffer directory, created protected and out of backup.
    nonisolated static func prepareDirectory(_ directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        protect(directory)
    }

    /// `completeUnlessOpen` (a segment being written when the phone locks can be finished, and
    /// nothing new can be opened) and excluded from backup — on the file itself, not only its
    /// directory, so the attribute the registry promises is the one each file carries.
    nonisolated static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                               ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// Delete the buffer directory and everything in it.
    nonisolated static func removeAll(in directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// At launch: whatever a crash or a kill left behind is not a buffer of any stream that is
    /// running now. Returns whether there was anything.
    @discardableResult
    nonisolated static func removeLeftovers(in directory: URL = defaultDirectory) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        removeAll(in: directory)
        PrivacyLog.recording(.replayBufferStopped, detail: PrivacyToken("launchCleanup"))
        return true
    }
}
