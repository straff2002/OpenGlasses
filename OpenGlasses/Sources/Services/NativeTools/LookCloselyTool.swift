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
final class LookCloselyTool: NativeTool {

    let name = "look_closely"

    let description = """
        Capture one sharp, full-resolution photo and add it to your view. Use this during a live \
        session when the answer depends on detail you cannot resolve in the streamed video — \
        small print, receipt line items, serial numbers, gauge or instrument markings, distant \
        signs. Only useful when the current view contains the thing to read; ask the user to hold \
        it steady first if needed.
        """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "reason": [
                    "type": "string",
                    "description": "What fine detail you are trying to read (for the log only)",
                ]
            ],
            "required": [],
        ]
    }

    /// Capture one full-resolution JPEG. Wired to `CameraService.capturePhoto`, which already
    /// prefers the glasses and falls back to the phone camera only when the glasses are
    /// unregistered — never silently swapping cameras on a registered failure.
    private let captureSharpFrame: () async throws -> Data
    /// The live session that can put the image in front of the model, or nil when none is active.
    private let injectorProvider: @MainActor () -> LiveSessionInjecting?
    private let posture: @MainActor () -> PowerPosture

    /// A capture that never arrives must not strand the model's function call.
    static let captureTimeout: Duration = .seconds(6)

    private var lastCaptureAt: Date?

    init(
        captureSharpFrame: @escaping () async throws -> Data,
        injectorProvider: @escaping @MainActor () -> LiveSessionInjecting?,
        posture: @escaping @MainActor () -> PowerPosture = { PowerPolicyService.shared.posture }
    ) {
        self.captureSharpFrame = captureSharpFrame
        self.injectorProvider = injectorProvider
        self.posture = posture
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let injector = injectorProvider(), injector.canInject else {
            // Direct mode (or a session that dropped mid-call): there is no live view to add an
            // image to. Point the model at the tools that carry their own vision instead.
            return "No live video session is active, so an image cannot be added to your view. Use a vision tool such as vision_assess or read_text instead — they capture and analyze a photo themselves."
        }

        let decision = LookCloselyPolicy.decide(
            posture: posture(),
            secondsSinceLastCapture: lastCaptureAt.map { Date().timeIntervalSince($0) })
        if case .declineWithReason(let reason) = decision {
            PrivacyLog.vision(.lookClosely, .declined)
            return reason
        }

        let jpeg: Data
        do {
            jpeg = try await Self.withTimeout(Self.captureTimeout) { [captureSharpFrame] in
                try await captureSharpFrame()
            }
        } catch is TimeoutError {
            PrivacyLog.vision(.lookClosely, .captureTimedOut)
            return "Couldn't get a sharp frame — the camera did not deliver a photo in time. Answer from the streamed view and say fine detail may be missing."
        } catch {
            PrivacyLog.vision(.lookClosely, .captureFailed, error: SafeErrorSummary(error))
            return "Couldn't get a sharp frame (\(error.localizedDescription)). Answer from the streamed view and say fine detail may be missing."
        }

        lastCaptureAt = Date()

        // Ordering is the contract: the image must be in the model's view before the function
        // result telling it to read that image.
        injector.injectSharpImage(jpegData: jpeg)
        PrivacyLog.vision(.lookClosely, .frameInjected, kilobytes: jpeg.count / 1024)
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
