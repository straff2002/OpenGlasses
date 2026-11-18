import Foundation

/// Smart camera's hold on the glasses video stream: taken when a turn needs a picture, and handed
/// back once the follow-up window (`Config.smartCameraCooldown`) has passed with no further use.
///
/// Smart camera used to call a bare `startStreaming()` and never stop it. The setting says "seconds
/// to keep the camera active after a vision query", but nothing ended it: one "what am I looking
/// at?" left the glasses camera streaming (capture LED on, battery draining) until the glasses
/// disconnected or a live session ended. It surfaced with build 717, when ChatGPT models began
/// taking photos and smart camera started opening the camera for ChatGPT wearers for the first time.
///
/// The hold is a `CameraStreamClaims` claim, so giving it back stops only a stream smart camera
/// started, and never one a live session, a recording or the wearer's preview still wants.
///
/// `keep(for:)` arms the release; each later use re-arms it, so a run of follow-up questions keeps
/// one warm stream. `nil` keeps it indefinitely: the "always" camera preset asks for exactly that.
@MainActor
final class SmartCameraStreamHold {
    private let claim: () async throws -> Void
    private let release: () async -> Void
    private var releaseTask: Task<Void, Never>?

    /// True between a claim that succeeded and the release that gave it back.
    private(set) var isHeld = false

    init(claim: @escaping () async throws -> Void, release: @escaping () async -> Void) {
        self.claim = claim
        self.release = release
    }

    /// Take the hold, starting the stream if nothing else has. A pending release is called off
    /// first, so it cannot land between the claim and the frame this turn is waiting for.
    func take() async throws {
        releaseTask?.cancel()
        releaseTask = nil
        try await claim()
        isHeld = true
    }

    /// Give the hold back after `delay` of no further use; `nil` keeps it until `giveBack()`.
    /// Does nothing when nothing is held.
    func keep(for delay: Duration?) {
        releaseTask?.cancel()
        releaseTask = nil
        guard isHeld, let delay else { return }
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.releaseTask = nil
            await self.giveBack()
        }
    }

    /// Give the hold back now.
    func giveBack() async {
        releaseTask?.cancel()
        releaseTask = nil
        guard isHeld else { return }
        isHeld = false
        await release()
    }

    /// How long a hold outlives its last use: the follow-up window, or for good under the
    /// "always" camera preset.
    nonisolated static func releaseDelay(cameraBehavior: String?, cooldown: TimeInterval) -> Duration? {
        guard cameraBehavior != "always" else { return nil }
        return .milliseconds(Int((max(cooldown, 0) * 1000).rounded()))
    }
}
