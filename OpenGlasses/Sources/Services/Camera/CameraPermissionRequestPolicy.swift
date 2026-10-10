import Foundation

/// Plan HX follow-up — whether a camera start may leave the app to ask for the glasses' camera
/// permission (pure).
///
/// # The gap this closes
///
/// Asking for the Meta camera permission deep-links out of the app to Meta AI. Plan HX P3 took
/// that out of the connection's own launch paths, which now only read the permission. Two camera
/// starts the app makes by itself were left: with a live mode selected the camera is started a
/// moment after launch, and "start Blind Assistant on launch" starts a session that claims it.
/// Both reach the backend's `ensurePermission()`, which asks when the permission is not granted.
/// So a registered wearer without the permission opened the app and was handed to Meta AI with
/// nobody having pressed anything.
///
/// # The rule
///
/// A camera start the wearer asked for (a button, a voice command, a tool call in a turn they
/// started) asks, as it always has. One the app began by itself reads the permission and, when it
/// is not granted, fails without asking: the permission's status is published as not granted, so
/// the diagnosis says camera access is needed (`GlassesReachabilityDiagnosis`), and the notice
/// names where the row to press is.
///
/// # How the two are told apart
///
/// By who began the work, said where it begins and carried with the task, never guessed from how
/// long ago launch was. The same shape as `TurnRecorder.isOffTurnWork`: the start travels through
/// the coordinator's coalescing task, a mode switch and a session manager before it reaches the
/// permission, and the task it runs on is the one thing all of those share. The default is the
/// wearer, so every existing caller keeps today's behaviour and only the app's own starts opt out.
///
/// One consequence, accepted: a wearer's start that joins an app-begun start already in flight
/// (`CameraService.startStreaming()` coalesces) gets that start's answer. It fails with the notice
/// that says what to press, and the next press asks.
enum CameraPermissionRequestPolicy {

    /// Who began the camera start in flight.
    enum Initiator: Equatable, Sendable {
        /// The wearer asked for it.
        case wearer
        /// The app began it by itself: at launch, on a return to the foreground, or resuming a
        /// session it had handed off.
        case app
    }

    /// Who began the work this task is doing. `.wearer` unless a caller said otherwise.
    @TaskLocal static var initiator: Initiator = .wearer

    /// Run `body` as work `initiator` began. Main-actor bound like its callers (`AppState`, the
    /// live-session activator), so the body never crosses an isolation boundary to be run.
    @MainActor
    static func begun<T>(by initiator: Initiator, _ body: () async throws -> T) async rethrows -> T {
        try await $initiator.withValue(initiator) { try await body() }
    }

    /// Run `body` as work the app began by itself: no camera start inside it leaves for Meta AI.
    @MainActor
    static func startedByApp<T>(_ body: () async throws -> T) async rethrows -> T {
        try await begun(by: .app, body)
    }

    enum Step: Equatable {
        /// The permission is granted. Carry on.
        case proceed
        /// Ask for it in Meta AI.
        case request
        /// Not granted, and nobody asked for this start: fail it and say what to press.
        case failWithoutAsking
    }

    /// What a camera start does once the permission has been read.
    static func step(granted: Bool, initiator: Initiator) -> Step {
        if granted { return .proceed }
        return initiator == .wearer ? .request : .failWithoutAsking
    }

    /// What the wearer is told when a start was failed rather than asked for. The session card's
    /// own hint for the same diagnosis, so the two cannot drift: it names Devices & Privacy ›
    /// Glasses, where "Allow camera access in Meta AI" is.
    static var notice: String { SessionCardGlassesPill.awayHint(for: .permissionNeeded) }
}
