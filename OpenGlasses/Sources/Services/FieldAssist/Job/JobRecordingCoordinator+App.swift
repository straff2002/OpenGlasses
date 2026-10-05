import AVFoundation
import Combine
import Foundation
import UIKit

// The app's own seams for "Record this job" (Plan HE): the recorder, the camera's raw publisher,
// the job log, the pairing gate and the on-device transcriber. `JobRecordingCoordinator` itself
// knows none of them.

/// The recorder a recorded job uses: a `VideoRecordingService` of its own, so the wearer's
/// ordinary recording — relay-fed, filed to the library — and a job's never share a writer, a
/// destination or a microphone handler.
///
/// It can only ever be asked for one thing: raw frames, written to the file it is given.
@MainActor
final class JobPartRecorder: JobPartRecording {
    private let recorder = VideoRecordingService()
    var onStalled: ((RecordingTimebase?) -> Void)?

    init(audio: (any BroadcastAudioProviding)?) {
        recorder.audioConsumerId = "job_recording_audio"
        recorder.audioProvider = audio
        // The recorder ends a part itself when the glasses stop sending pictures. What it says
        // about the save is for the library recording; here the part's timing is what matters.
        recorder.onAutoStopped = { [weak self] _ in
            guard let self else { return }
            self.onStalled?(self.recorder.lastTimebase)
        }
    }

    func startPart(from frames: PassthroughSubject<UIImage, Never>, to file: URL) throws {
        do {
            try recorder.startRecording(from: frames, destination: .file(file), source: .rawForOfficeRecording)
        } catch is VideoRecordingService.InsufficientStorageError {
            throw JobPartStartError.notEnoughStorage
        } catch {
            throw JobPartStartError.couldNotStart
        }
        guard recorder.isRecording else { throw JobPartStartError.couldNotStart }
    }

    func finishPart() async -> RecordingTimebase? {
        guard await recorder.stopRecording() != nil else { return nil }
        return recorder.lastTimebase
    }
}

extension JobRecordingCoordinator {
    /// The raw tap (`OutboundFrameConsumer.jobRecordingCapture`): the camera's own publisher, not
    /// the blur relay's. The one place a recorded job is given its frames, so the roster's test
    /// can find it and nothing else has to know which publisher that is.
    static func rawFrames(from cameraService: CameraService) -> PassthroughSubject<UIImage, Never> {
        cameraService.framePublisher
    }

    /// The host clock the recorder stamps samples with, in seconds.
    nonisolated static func hostClockSeconds() -> TimeInterval {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }
}

extension JobRecordingCoordinator.Seams {
    /// The seams as the app wires them. The camera and the microphone come from the caller; the
    /// rest is read where it lives.
    @MainActor
    static func app(cameraService: CameraService,
                    audio: (any BroadcastAudioProviding)?,
                    hipaa: HIPAAComplianceService?,
                    bundles: JobRecordingBundleStore,
                    blur: JobPartBlur? = nil,
                    pairing: @escaping @MainActor () -> OfficePairingService = { OfficePairingService() },
                    sessions: @escaping @MainActor () -> FieldSessionService = { .shared }) -> Self {
        Self(
            rules: {
                .init(officeTransportInBuild: OfficeTransportIdentity.isAvailable,
                      fieldAssistEntitled: Config.fieldAssistUnlocked,
                      organizationForbidsRecording: Config.organizationForbidsJobRecording,
                      organizationRequiresBlur: Config.organizationRequiresBlurBeforeOfficeSync,
                      medicalComplianceMode: Config.hipaaMode,
                      officeRouteRefused: MedicalEgressGuard.blocks(.jobRecordingOfficeSync))
            },
            binding: {
                guard let payload = try? await pairing().currentApprovedPeer().binding.payload else { return nil }
                return .init(organizationID: payload.organizationID, enrolmentID: payload.enrolmentID,
                             officeID: payload.officeID, generation: payload.generation,
                             phoneTransportID: payload.phoneTransportID)
            },
            job: {
                let service = sessions()
                guard service.isOpenForEvidence, let session = service.activeSession else { return nil }
                return .init(sessionID: session.id, jobNumber: session.jobReference)
            },
            consent: { Config.jobRecordingConsent },
            saveConsent: { Config.jobRecordingConsent = $0 },
            recorder: JobPartRecorder(audio: audio),
            frames: { JobRecordingCoordinator.rawFrames(from: cameraService) },
            readiness: { cameraService.readinessNow },
            ensureStream: {
                do {
                    try await cameraService.claimStream(for: .jobRecording)
                } catch {
                    return .claimFailed
                }
                return await ClipStreamWarmup.waitForFreshEvidence(readiness: { cameraService.readinessNow })
            },
            releaseStream: { await cameraService.releaseStream(for: .jobRecording) },
            capture: JobRecordingCaptureStore(sessionsRoot: bundles.sessionsRoot),
            bundles: bundles,
            sign: { try await OfficePhoneIdentity.shared.signRecordingManifest($0) },
            blur: blur,
            transcribe: TimedTranscriptSource.onDevice().utterances,
            logEntries: { sessionID in
                JobRecordingLogReader.entries(
                    SessionLogger.readEvents(at: sessions().sessionDirectory(sessionId: sessionID)))
            },
            log: { sessionID, kind, payload in
                sessions().logRecording(kind, sessionId: sessionID, payload: payload)
            },
            auditConsent: { acknowledgement in
                hipaa?.record(.consentChanged, actor: .wearer, target: .consent, purpose: .wearerRequest,
                              count: acknowledgement.wordingVersion)
            },
            monotonicNow: { JobRecordingCoordinator.hostClockSeconds() })
    }
}

extension JobPartBlur {
    /// The blur pass as the app wires it: `BundleBlurPass` over the app's one face blur, run only
    /// while the app is in front and the blur says it can be relied on.
    @MainActor
    static func app(filter: PrivacyFilterService) -> JobPartBlur {
        // Both are asked: the filter's own view of the app's life, and the application's. Either
        // one saying no is no.
        let available: @MainActor () -> Bool = {
            UIApplication.shared.applicationState == .active && !filter.isSuspendedForBackground
        }
        let pass = BundleBlurPass.app(filter: filter, isAvailable: available)
        // The phone is let lock itself again exactly as it would have before: something else may
        // have asked for it to stay awake meanwhile.
        var stayedAwakeBefore = false
        return JobPartBlur(
            isAvailable: available,
            blur: { part, output, progress in
                switch await pass.run(part: part, output: output, progress: progress) {
                case .success(let report): return .success(report)
                case .failure(.interrupted): return .failure(.interrupted)
                case .failure: return .failure(.failed)
                }
            },
            keepAwake: { awake in
                if awake {
                    stayedAwakeBefore = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                } else {
                    UIApplication.shared.isIdleTimerDisabled = stayedAwakeBefore
                }
            })
    }
}

/// The lines of a job's log that belong on a recording's timeline: the turns, the photographs and
/// the procedure runner's steps. An instruction the app sent on the technician's behalf is not a
/// turn — nobody said it.
enum JobRecordingLogReader {
    static func entries(_ events: [SessionLogger.Event]) -> [RecordedJobAssembly.LogEntry] {
        events.compactMap { event in
            func value(_ key: String) -> String? {
                (event.payload?[key]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch event.kind {
            case .userMessage:
                guard !text.isEmpty else { return nil }
                return .init(at: event.timestamp, kind: .technicianTurn(ref: value("source_id"), text: text))
            case .assistantMessage:
                guard !text.isEmpty else { return nil }
                return .init(at: event.timestamp, kind: .assistantTurn(ref: value("source_id"), text: text))
            case .photoAttached:
                return .init(at: event.timestamp, kind: .photo(ref: value("path")))
            case .procedureStarted:
                return .init(at: event.timestamp, kind: .procedureStarted(procedureID: value("procedure_id")))
            case .procedureStep:
                return .init(at: event.timestamp, kind: .procedureStep(stepID: value("step_id")))
            case .procedureCompleted:
                return .init(at: event.timestamp, kind: .procedureCompleted(procedureID: value("procedure_id")))
            default:
                return nil
            }
        }
    }
}

/// Where a recording's timed words come from (Plan GY's seam, carried here by Plan HE).
///
/// On the phone, and only on the phone: the recording's sound is read in short windows and each is
/// transcribed by the on-device recogniser, so a step boundary is never off by more than a window.
/// The cloud transcriber is not used for a recorded job — the consent a technician acknowledges
/// names one destination, their organisation's office, and a transcription vendor is not it.
///
/// When the on-device recogniser is not ready there are no words. The recording is sealed without
/// them, the turns keep their log times, and the office may transcribe for itself.
struct TimedTranscriptSource {
    /// The words in one recorded part, timed from the part's first audio sample.
    let utterances: @MainActor (URL) async -> [TimedTranscript.Utterance]

    static let none = TimedTranscriptSource { _ in [] }

    /// How long each window is. Plan GY: ten seconds for a walkthrough.
    static let windowSeconds: TimeInterval = 10

    /// The recogniser is made the first time a recording is transcribed, not when the app starts.
    @MainActor
    static func onDevice(engine: @escaping @MainActor () -> OnDeviceASREngine = { OnDeviceASREngine() },
                         windowSeconds: TimeInterval = TimedTranscriptSource.windowSeconds) -> TimedTranscriptSource {
        let held = HeldEngine(make: engine)
        return TimedTranscriptSource { file in
            let engine = held.engine
            guard engine.isReady, let reader = await RecordedPartAudioReader(file: file) else { return [] }
            var utterances: [TimedTranscript.Utterance] = []
            // A recording deleted while its words are being read is not read to the end: the
            // pass that asked is cancelled, and throws away what comes back.
            while !Task.isCancelled, let window = await reader.next(seconds: windowSeconds) {
                guard let text = try? await engine.transcribe(samples: window.samples, sampleRate: window.sampleRate)
                else { continue }
                if let utterance = utterance(text: text, offset: window.offset, duration: window.duration) {
                    utterances.append(utterance)
                }
            }
            return utterances
        }
    }

    @MainActor
    private final class HeldEngine {
        private let make: @MainActor () -> OnDeviceASREngine
        private var made: OnDeviceASREngine?
        init(make: @escaping @MainActor () -> OnDeviceASREngine) { self.make = make }
        var engine: OnDeviceASREngine {
            if let made { return made }
            let engine = make()
            made = engine
            return engine
        }
    }

    /// One window's words as an utterance: it began when the window did and ended when the window
    /// did, which is as near as a window can say. Nil for a window with no words.
    static func utterance(text: String, offset: TimeInterval, duration: TimeInterval) -> TimedTranscript.Utterance? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, offset >= 0, duration > 0 else { return nil }
        return .init(start: SessionTime(seconds: offset), end: SessionTime(seconds: offset + duration), text: words)
    }
}

/// Reads the sound of one recorded part a window at a time, as mono 16 kHz samples, without ever
/// holding the whole part in memory.
actor RecordedPartAudioReader {
    struct Window: Sendable {
        let samples: [Float]
        let sampleRate: Double
        /// Seconds from the part's first audio sample to the start of this window.
        let offset: TimeInterval
        let duration: TimeInterval
    }

    static let sampleRate: Double = 16_000

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var carried: [Float] = []
    private var delivered = 0
    private var finished = false

    /// Nil when the file cannot be read or holds no sound.
    init?(file: URL) async {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        self.reader = reader
        self.output = output
    }

    /// The next window, or nil at the end. The last window may be shorter.
    func next(seconds: TimeInterval) -> Window? {
        let wanted = max(1, Int(seconds * Self.sampleRate))
        while carried.count < wanted, !finished {
            guard reader.status == .reading, let buffer = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(buffer) else {
                finished = true
                break
            }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let copied = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: base)
            }
            if copied == kCMBlockBufferNoErr { carried.append(contentsOf: samples) }
        }
        guard !carried.isEmpty else { return nil }
        let take = min(wanted, carried.count)
        let window = Window(samples: Array(carried.prefix(take)), sampleRate: Self.sampleRate,
                            offset: Double(delivered) / Self.sampleRate, duration: Double(take) / Self.sampleRate)
        carried.removeFirst(take)
        delivered += take
        return window
    }
}
