import Foundation

/// Plan CB P2 — `look_closely`: one sharp frame for the live model, on demand.
///
/// The live-session stream is throttled and encoded small, which is right for continuity and wrong
/// for reading: printed line items on a receipt are a few pixels tall at stream size, and JPEG
/// discards thin strokes first — the detail is gone before inference starts. This tool captures a
/// single full-resolution still, pushes it into the live model's *own* view, and returns an
/// instruction to read from it. The model keeps the image, so follow-ups work — unlike routing
/// through a second model whose summary is all the live model ever sees.
///
/// # Wiring rule (the silent-failure trap)
///
/// The injector is resolved through a closure at *execution* time, never captured at construction.
/// Session managers are built in `startSession()` and dropped on stop, while this tool lives for
/// the process. A provider captured directly would go stale after the first session teardown and
/// the tool would report "no live session" forever — which reads as a hardware fault, not a wiring
/// mistake.
///
/// # Plan FF P1/PR4 — what a capture now has to prove before it is injected
///
/// A capture that returned without throwing used to be treated as an answer. Three things were
/// never checked, and each of them is a way for a blind wearer to be read the wrong thing:
///
/// * **Privacy.** The capture went straight to `CameraService.capturePhoto()`, the unfiltered
///   accessor, and the pixels went to a cloud realtime session. It now goes through the still
///   chokepoint under `PrivacyFilterScope.liveSession`, the same scope the streamed frames beside
///   it already travel under. See `SharpStillCapture`.
/// * **Quality.** A blurred or unlit still produces a confident-sounding answer built out of what
///   the model expects a medication box to say. A measured `CaptureQualityReport` decides, one
///   automatic re-capture is allowed, and then the wearer is told what to change.
/// * **Identity.** Capture takes seconds. A reconnect inside that window replaces the session, and
///   `canInject` goes true again for the *new* one — so a still captured for the old conversation
///   would be delivered into a conversation that never asked for it. The still is stamped with the
///   session and camera it belongs to and with the moment it was taken, and a mismatch is refused.
final class LookCloselyTool: NativeTool {

    let name = "look_closely"

    /// Composed, not written out, so the phrases the model is shown and the phrases
    /// `ReadingRequestClassifier` recognises cannot drift apart.
    ///
    /// The first sentence and the fine-detail list are unchanged. What PR4's routing audit added is
    /// the second half: the audit found that a wearer's actual words — "read this", "what does this
    /// say", "what's the expiry date" — appeared nowhere in the description the model selects from,
    /// which named only receipt line items, serial numbers and gauge markings. The model was being
    /// asked to make the leap from "read me this label" to "instrument markings" unaided.
    var description: String {
        let phrases = ReadingRequestClassifier.triggerPhrases
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return """
            Capture one sharp, full-resolution photo and add it to your view. Use this during a \
            live session when the answer depends on detail you cannot resolve in the streamed video \
            — small print, receipt line items, serial numbers, gauge or instrument markings, \
            distant signs. ALWAYS use it before reading text the user asked for: \(phrases), and \
            any request for a specific printed value such as a price, a total, a dose or a date. \
            Do not read printed text out of the streamed video when this tool is available. Only \
            useful when the current view contains the thing to read; ask the user to hold it steady \
            first if needed.
            """
    }

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "reason": [
                    "type": "string",
                    "description": "What the user asked for, in their own words where you have them — e.g. 'read this label', 'what's the expiry date'. Used to pick the right guidance if the photo comes out unreadable.",
                ]
            ],
            "required": [],
        ]
    }

    /// Capture one full-resolution JPEG through the privacy chokepoint and measure it. Takes the
    /// live-session identity the capture is being made for, so the report can be stamped with it.
    ///
    /// Throwing, and not only because the timeout wrapper does: the chokepoint reports *why* it
    /// could not produce a still through `FilteredStillResult.Reason`, but a source that can name
    /// a device error should be able to say so rather than have it flattened into "no still".
    private let captureSharpStill: (Int) async throws -> ReadingCaptureResult
    /// The live session that can put the image in front of the model, or nil when none is active.
    private let injectorProvider: @MainActor () -> LiveSessionInjecting?
    /// The camera session that is current right now (`CameraReadiness.session`).
    private let cameraSession: @MainActor () -> Int
    private let posture: @MainActor () -> PowerPosture
    /// On-device text recognition, used only on the failure path to offer a partial transcription.
    private let recognizeText: (Data) async -> OCRService.Result
    private let now: () -> Date
    /// Plan FF P0/PR2 — fired at the capture-succeeded boundary and nowhere else.
    ///
    /// This is the wearer's "requested photo captured" feedback, so *where* it is called is the
    /// whole requirement: not when the model asks for a photo, not when the policy allows one, and
    /// not on the repeated background frames the live session is already sending. A blind wearer
    /// holding a medicine box steady needs to know the picture exists — and must not be told it
    /// does when the capture timed out, or when what came back was too blurred to read.
    private let onCaptureSucceeded: @MainActor () -> Void

    /// A capture that never arrives must not strand the model's function call.
    static let captureTimeout: Duration = .seconds(6)

    /// When a photo was last actually put in front of the model.
    ///
    /// Plan FF P1/PR4 moved this from "last successful capture" to "last *injected* capture", which
    /// is what `LookCloselyPolicy`'s cooldown text already claimed ("a sharp photo was captured
    /// only moments ago and is already in your view"). A capture that was discarded as unreadable
    /// never entered the model's view, and must not lock the wearer out of asking again for five
    /// seconds.
    private var lastInjectionAt: Date?

    init(
        captureSharpStill: @escaping (Int) async throws -> ReadingCaptureResult,
        injectorProvider: @escaping @MainActor () -> LiveSessionInjecting?,
        cameraSession: @escaping @MainActor () -> Int,
        posture: @escaping @MainActor () -> PowerPosture = { PowerPolicyService.shared.posture },
        recognizeText: @escaping (Data) async -> OCRService.Result = { data in
            await OCRService().recognizeText(in: data)
        },
        now: @escaping () -> Date = Date.init,
        onCaptureSucceeded: @escaping @MainActor () -> Void = {}
    ) {
        self.captureSharpStill = captureSharpStill
        self.injectorProvider = injectorProvider
        self.cameraSession = cameraSession
        self.posture = posture
        self.recognizeText = recognizeText
        self.now = now
        self.onCaptureSucceeded = onCaptureSucceeded
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let injector = injectorProvider(), injector.canInject else {
            // Direct mode (or a session that dropped mid-call): there is no live view to add an
            // image to. Point the model at the tools that carry their own vision instead.
            return "No live video session is active, so an image cannot be added to your view. Use a vision tool such as vision_assess or reading_assist instead — they capture and analyze a photo themselves."
        }

        let decision = LookCloselyPolicy.decide(
            posture: posture(),
            secondsSinceLastCapture: lastInjectionAt.map { now().timeIntervalSince($0) })
        if case .declineWithReason(let reason) = decision {
            PrivacyLog.vision(.lookClosely, .declined)
            return reason
        }

        let requestedAt = now()
        let requestIdentity = injector.liveSessionIdentity
        let isReadingRequest = ReadingRequestClassifier
            .isReadingRequest(args["reason"] as? String ?? "")

        var attempts = 0
        var degraded: (jpeg: Data, report: CaptureQualityReport)?

        while true {
            attempts += 1

            // The retry is a *request* to capture, not a bypass: power posture still decides.
            // (The cooldown deliberately does not gate it — nothing was injected, so nothing is
            // "already in your view", which is the only thing the cooldown's reason claims.)
            if attempts > 1, posture() == .reserve {
                PrivacyLog.vision(.lookClosely, .declined)
                break
            }

            let outcome: ReadingCaptureResult
            do {
                outcome = try await Self.withTimeout(Self.captureTimeout) { [captureSharpStill] in
                    try await captureSharpStill(requestIdentity)
                }
            } catch is TimeoutError {
                PrivacyLog.vision(.lookClosely, .captureTimedOut)
                return "Couldn't get a sharp frame — the camera did not deliver a photo in time. The detail that needed the photo is still unread: do NOT answer it from the streamed view. Tell the user the photo did not arrive, ask them to hold the item steady, and offer to try again. Never guess characters, digits, names or dates."
            } catch {
                PrivacyLog.vision(.lookClosely, .captureFailed, error: SafeErrorSummary(error))
                return "Couldn't get a sharp frame (\(error.localizedDescription)). The detail that needed the photo is still unread: do NOT answer it from the streamed view. Tell the user the photo failed, ask them to hold the item steady, and offer to try again. Never guess characters, digits, names or dates."
            }

            let jpeg: Data
            let report: CaptureQualityReport
            switch outcome {
            case .unavailable(let reason):
                // The chokepoint's own reason, carried through verbatim: no picture, no *current*
                // picture, and could-not-filter are three different things to tell a wearer.
                PrivacyLog.vision(.lookClosely, .captureFailed,
                                  reason: PrivacyToken(reason.rawValue))
                return ReadingCaptureOutcome.unavailable(reason)
            case .captured(let data, let measured):
                jpeg = data
                report = measured
            }

            switch ReadingCaptureOutcome.decide(quality: report.quality,
                                                attemptsSoFar: attempts,
                                                isReadingRequest: isReadingRequest) {
            case .retry(let quality):
                PrivacyLog.vision(.lookClosely, .captureRetried,
                                  reason: PrivacyToken(quality.rawValue),
                                  kilobytes: report.jpegByteCount / 1024)
                degraded = (jpeg, report)
                continue
            case .explain:
                degraded = (jpeg, report)
                // Fall out of the loop; the copy is chosen below, after the OCR attempt.
            case .inject:
                return await inject(jpeg: jpeg, report: report,
                                    requestedAt: requestedAt, requestIdentity: requestIdentity)
            }
            break
        }

        // Unusable after the bounded retry. Offer what on-device recognition could actually read,
        // or the instruction — never a reconstruction of what the item probably says.
        guard let degraded else {
            return ReadingCaptureOutcome.unavailable(.noStill)
        }
        PrivacyLog.vision(.lookClosely, .captureUnusable,
                          reason: PrivacyToken(degraded.report.quality.rawValue),
                          count: attempts,
                          kilobytes: degraded.report.jpegByteCount / 1024)
        let recognized = await recognizeText(degraded.jpeg)
        if let partial = ReadingCaptureOutcome.confidentText(from: recognized) {
            PrivacyLog.vision(.lookClosely, .textRecognized,
                              count: recognized.blocks.count, characters: partial.count)
            return ReadingCaptureOutcome.partialTranscription(partial,
                                                              quality: degraded.report.quality)
        }
        return ReadingCaptureOutcome.instruction(for: degraded.report.quality,
                                                 isReadingRequest: isReadingRequest)
    }

    // MARK: - Injection

    /// The one place bytes reach the model, and the last place their provenance is checked.
    ///
    /// The three guards are re-evaluated *here*, against the world as it is now rather than as it
    /// was when the capture started, because the whole failure being prevented happened during the
    /// capture. A refusal reports `noFreshView` — the existing name for "there is a picture and it
    /// is not a current view" — so a session replacement and a picture that aged out tell the
    /// wearer the same true thing.
    @MainActor
    private func inject(jpeg: Data,
                        report: CaptureQualityReport,
                        requestedAt: Date,
                        requestIdentity: Int) async -> String {
        guard let injector = injectorProvider(), injector.canInject else {
            PrivacyLog.vision(.lookClosely, .captureStale,
                              reason: PrivacyToken(CaptureQualityReport.Refusal.sessionReplaced.rawValue))
            return ReadingCaptureOutcome.unavailable(.noFreshView)
        }
        if let refusal = report.refusal(requestedAt: requestedAt,
                                        liveSessionIdentity: injector.liveSessionIdentity,
                                        cameraSession: cameraSession()) {
            PrivacyLog.vision(.lookClosely, .captureStale,
                              reason: PrivacyToken(refusal.rawValue))
            return ReadingCaptureOutcome.unavailable(refusal.stillReason)
        }

        lastInjectionAt = now()
        // The image exists, is readable, and belongs to this request and this session. Every other
        // exit from this function has already returned.
        onCaptureSucceeded()

        // Ordering is the contract: the image must be in the model's view before the function
        // result telling it to read that image.
        injector.injectSharpImage(jpegData: jpeg)
        PrivacyLog.vision(.lookClosely, .frameInjected, kilobytes: report.jpegByteCount / 1024,
                          detail: PrivacyToken(report.quality.rawValue))
        return LookCloselyPolicy.sharpFrameInstruction
    }

    // MARK: - Timeout

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }
}
