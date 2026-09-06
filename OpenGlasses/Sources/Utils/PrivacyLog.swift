import Foundation
import CryptoKit
import os

/// Structured, metadata-only logging for production builds.
///
/// A device log is readable by anything with the device in hand, survives into sysdiagnose
/// bundles, and is the one place in the app where content escapes every other control we built —
/// the vault encryption, the egress screen, the privacy filter. So the rule here is not "redact
/// carefully": there is **no production method that accepts an arbitrary `String` message**.
/// Callers pass a fixed event name, counts, durations, outcome enums, and identifiers they have
/// explicitly wrapped in `PrivateIdentifier` (which hashes them). A transcript, a tool argument,
/// a QR payload, a URL with a query, or a `localizedDescription` has no parameter to arrive in.
///
/// The classification this implements:
///
/// | Class | Treatment here |
/// |---|---|
/// | Public operation | event name, counts, durations, `Bool` outcomes — persisted |
/// | Private identifier | `PrivateIdentifier` — one-way fingerprint only |
/// | User content | no parameter accepts it |
/// | Secret | no parameter accepts it |
/// | Regulated/sensitive | counts and operation classes only |
///
/// Errors inherit the classification of the request that produced them, so error paths take a
/// `SafeErrorSummary` rather than an `Error`: see that type for why `localizedDescription` is
/// never read.
enum PrivacyLog {

    // MARK: - Categories

    /// Fixed subsystem categories. Adding one is a deliberate act — a category is how a reader
    /// (and a future diagnostics export) filters, so an open-ended set defeats the point.
    enum Category: String {
        /// Tool dispatch: which tool, how long, what verdict.
        case tools
        /// Live model sessions (Gemini Live, OpenAI Realtime): state, counts, timing.
        case realtime
        /// Camera-derived capture: QR, frames.
        case capture
        /// Home/automation control. Entities and commands are regulated — counts only.
        case home
        /// App lifecycle and inbound links.
        case lifecycle
        /// Sign-in and credential refresh. Never a token, never a callback URL.
        case auth
        /// Transport-level request failures, below the operation that asked for them.
        case network
        /// The agent gateway link: endpoint selection, socket lifecycle, pairing, protocol calls.
        case gateway
        /// Model Context Protocol — both the client we run and the local server we expose.
        case mcp
        /// Outbound media links: viewer broadcast, expert bridge, HUD mirror, their signalling.
        case stream
        /// Wake word, recognition, transcription, captions, translation, speech synthesis.
        case speech
        /// The audio graph beneath all of it: sessions, routes, engines, interruptions.
        case audio
        /// Model turns — cloud and on-device — their lifecycle, cost and failures.
        case model
        /// Stored conversation history and its encryption.
        case conversation
        /// What the cameras were asked to see: OCR, scene narration, faces, sign language.
        /// Everything recognised here is regulated or user content — this category carries
        /// counts and outcomes only.
        case vision
        /// Clinical operations: protected storage, the audit trail's own faults, exports.
        /// A clinical value, a medication, a condition or an export's contents never appear.
        case medical
        /// Where the wearer is. Coordinates, place names and region identifiers have no
        /// parameter anywhere in this category.
        case location
        /// Local persistence: what a store did, how much of it, and how a damaged blob was
        /// salvaged. Never a record, a key, a value, or a file's name.
        case store
        /// Data crossing the app's boundary: import, export, share, and the drain that hands the
        /// offline queue to the network. Manifest counts and format classes only.
        case transfer
        /// The glasses link and the app's other surfaces — the watch, the car, the lock screen,
        /// the in-lens HUD, the Now Playing slot. Link states and surface lifecycle; never a
        /// device id in the clear, never the content a surface was asked to show.
        case device
        /// Work the app schedules and delivers on the wearer's behalf: the task scheduler, the
        /// notification queue that speaks its results, the agent's own session plumbing. Task
        /// titles and notification bodies are the wearer's day — kind, count and outcome only.
        case agent
        /// Purchases and entitlements. Product ids are this app's own published catalog; nothing
        /// about the buyer, the receipt, or the payment ever appears.
        case commerce
    }

    // MARK: - Sink

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.openglasses.app"

    private static let loggers: [Category: Logger] = {
        var made: [Category: Logger] = [:]
        for category in [Category.tools, .realtime, .capture, .home, .lifecycle, .auth, .network,
                         .gateway, .mcp, .stream, .speech, .audio, .model, .conversation,
                         .vision, .medical, .location, .store, .transfer,
                         .device, .agent, .commerce] {
            made[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return made
    }()

    /// The one place an event reaches the OS. Everything above it is pure and testable; the
    /// encoded line is marked `.public` because, by construction, nothing private got into it.
    @discardableResult
    static func emit(_ event: PrivacyEvent) -> PrivacyEvent {
        let line = PrivacyEventEncoder.encode(event)
        loggers[event.category]?.log("\(line, privacy: .public)")
        for tap in currentTaps() { tap(event, line) }
        return event
    }

    // MARK: - Taps
    //
    // A second reader of the same encoded line. This exists for two callers and takes no new
    // risk from either: the in-memory diagnostics ring the wearer can export, and the canary
    // fixtures that drive a subsystem and assert nothing recognisable came out the other end.
    //
    // The tap is handed the event *and the exact string the OS received* — not the raw
    // arguments a call site passed — so a tap cannot see anything the log does not already
    // contain, and an export built from taps can never be broader than the log itself.

    /// Handle for removing a tap. Opaque so a caller cannot forge or enumerate one.
    struct TapToken: Hashable {
        fileprivate let id: UUID
    }

    private static let tapLock = NSLock()
    private nonisolated(unsafe) static var taps: [UUID: (PrivacyEvent, String) -> Void] = [:]
    /// Rebuilt on add/remove so the emit path copies a reference rather than rebuilding an array
    /// on every event — this runs on the camera and audio paths.
    private nonisolated(unsafe) static var tapList: [(PrivacyEvent, String) -> Void] = []

    /// Observe every event from now on. Returns the token that stops it again.
    static func addTap(_ tap: @escaping (PrivacyEvent, String) -> Void) -> TapToken {
        let token = TapToken(id: UUID())
        tapLock.lock()
        taps[token.id] = tap
        tapList = Array(taps.values)
        tapLock.unlock()
        return token
    }

    static func removeTap(_ token: TapToken) {
        tapLock.lock()
        taps.removeValue(forKey: token.id)
        tapList = Array(taps.values)
        tapLock.unlock()
    }

    /// Snapshot under the lock, call outside it: a tap that logs (the ring does not, but a test
    /// sink might) would otherwise re-enter `emit` while the lock is held.
    private static func currentTaps() -> [(PrivacyEvent, String) -> Void] {
        tapLock.lock()
        defer { tapLock.unlock() }
        return tapList
    }

    // MARK: - Debug-only content escape hatch
    //
    // Deliberately gated behind BOTH `DEBUG` and a compilation condition that is defined in no
    // build configuration in this repo (`project.base.yml` / `project.tests.yml`). Turning it on
    // is a local, uncommitted edit; a test asserts the flag never appears in a checked-in spec.
    // The prefix is conspicuous so a line that escapes into a shared log is obvious on sight.
    #if DEBUG && ENABLE_CONTENT_LOGGING
    static func debugContent(_ category: Category, _ name: PrivacyEvent.Name,
                             _ content: @autoclosure () -> String) {
        loggers[category]?.debug(
            "⚠️ CONTENT-LOG (debug only) \(name.rawValue, privacy: .public): \(content(), privacy: .private)")
    }
    #endif

    // MARK: - Tools

    /// Outcome classes mirror `ToolExecutionOutcome`'s cases without their reason strings — the
    /// reason is the tool's own text, i.e. user content.
    enum ToolOutcome: String {
        case completed, rejected, failedBeforeExecution, outcomeUnknown
    }

    @discardableResult
    static func toolCallReceived(name: String, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallReceived, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallRefused(name: String, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallRefused, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallAcked(name: String, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallAcked, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallCancelled(invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallCancelled, [
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
        ]))
    }

    @discardableResult
    static func toolCallCompleted(name: String, invocation: String,
                                  outcome: ToolOutcome, durationMs: Int) -> PrivacyEvent {
        return emit(.init(.tools, .toolCallCompleted, [
            .init(.tool, .token(PrivacyToken(name))),
            .init(.invocation, .identifier(PrivateIdentifier(invocation))),
            .init(.outcome, .token(PrivacyToken(outcome.rawValue))),
            .init(.duration, .milliseconds(durationMs)),
        ]))
    }

    /// Why a tool did not run, decided before anything executed.
    ///
    /// The reason strings behind these verdicts are not kept. The safety supervisor's reason, the
    /// confirmation prompt and the egress screen's explanation are each built from the tool's own
    /// arguments — "send 'meet at 8' to Dr Alvarez?" — so quoting one would log the argument the
    /// gate exists to hold back.
    enum ToolGateVerdict: String {
        case blockedBySafety, heldForReengagement, noConfirmationCoordinator
        case confirmationRequired, declinedByUser, egressWithheld, alreadyJournaled
    }

    @discardableResult
    static func toolGate(_ verdict: ToolGateVerdict, tool: String,
                         detail: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.verdict, .token(PrivacyToken(verdict.rawValue))),
            .init(.tool, .token(PrivacyToken(tool))),
        ]
        if let detail { fields.append(.init(.detail, .token(detail))) }
        return emit(.init(.tools, .toolGate, fields))
    }

    /// One refusal, as recorded in the authorization ring.
    ///
    /// The verdict is `ToolAuthorizationPolicy`'s own fixed vocabulary and the invocation arrives
    /// already fingerprinted, so this is the one tool event whose fields are all pre-classified by
    /// the caller — it still goes through the vocabulary filter.
    @discardableResult
    static func toolAuthorizationRefused(verdict: String, tool: String, origin: String,
                                         depth: Int, invocation: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolAuthorizationRefused, [
            .init(.verdict, .token(PrivacyToken(verdict))),
            .init(.tool, .token(PrivacyToken(tool))),
            .init(.source, .token(PrivacyToken(origin))),
            .init(.count, .count(depth)),
            .init(.invocation, .token(PrivacyToken(invocation))),
        ]))
    }

    /// Which executor took the call. Tool names are the app's own fixed vocabulary.
    enum ToolRoute: String { case native, mcp, gateway }

    @discardableResult
    static func toolDispatch(_ route: ToolRoute, tool: String) -> PrivacyEvent {
        return emit(.init(.tools, .toolDispatch, [
            .init(.route, .token(PrivacyToken(route.rawValue))),
            .init(.tool, .token(PrivacyToken(tool))),
        ]))
    }

    /// What happened to a dispatched call. `characters` is how much the tool returned; the return
    /// value itself is the tool's answer about the wearer's world and has no parameter here.
    enum ToolRunEvent: String {
        case succeeded, failed, outcomeUnknown
        case stillRunning, lateCompletion, resolvedLate, reconciled
    }

    @discardableResult
    static func toolRun(_ event: ToolRunEvent, tool: String? = nil, seconds: Double? = nil,
                        count: Int? = nil, characters: Int? = nil,
                        detail: PrivacyToken? = nil,
                        error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let tool { fields.append(.init(.tool, .token(PrivacyToken(tool)))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.tools, .toolRun, fields))
    }

    /// A web search ran. The query is the wearer's question — the most sensitive string a search
    /// tool ever holds, and the one thing a search log is always tempted to include — so the
    /// provider, the verdict and the size of the answer are all that survive.
    enum SearchProvider: String { case perplexity, tavily, brave, duckDuckGo }

    @discardableResult
    static func webSearch(_ provider: SearchProvider, succeeded: Bool, status: Int? = nil,
                          results: Int? = nil, error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.success, .flag(succeeded)),
        ]
        if let status { fields.append(.init(.status, .count(status))) }
        if let results { fields.append(.init(.count, .count(results))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.tools, .webSearch, fields))
    }

    // MARK: - Realtime sessions

    enum RealtimeProvider: String { case openai, gemini }

    /// State transitions and protocol milestones. No case carries model or user text.
    ///
    /// The session-manager half of this vocabulary (camera, audio mode, tool pausing) describes a
    /// live session's *plumbing*. The system instruction is the one thing here that could carry
    /// content — it embeds the wearer's location, personas and memory context — so it appears only
    /// as `characters`.
    enum RealtimeSessionEvent: String {
        case sessionCreated, sessionConfigured, sessionUpdateSent, sessionStopped
        case userInterrupted, intentionalDisconnect, reconnected
        case modelSubstituted, unhandledEvent
        case cameraStarted, firstCameraFrame, frameForwarded, frameDropped, framePolled
        case framePollingStarted, lateCameraRetried, visionReconfigured
        case systemInstructionBuilt, gatewayToolOmitted
        case audioModeSelected, audioModeUnchanged, audioModeSwitched, audioModeSwitchFailed
        case audioRestartFailed, toolExecutionPaused, toolExecutionResumed
        case postConnectState
    }

    enum UtteranceDirection: String { case input, output }
    enum RealtimeMediaKind: String { case streamedFrame, sharpFrame }
    enum RealtimeSendKind: String { case text, image, frame }
    enum RealtimeSkipReason: String { case notReady, encodingFailed }
    enum RealtimeErrorPhase: String { case send, receive, fatal, recoverable }

    @discardableResult
    static func realtimeSession(_ provider: RealtimeProvider, _ event: RealtimeSessionEvent,
                                detail: PrivacyToken? = nil, state: PrivacyToken? = nil,
                                count: Int? = nil, total: Int? = nil, characters: Int? = nil,
                                success: Bool? = nil,
                                error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let state { fields.append(.init(.state, .token(state))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let total { fields.append(.init(.total, .count(total))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let success { fields.append(.init(.success, .flag(success))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.realtime, .realtimeSession, fields))
    }

    /// One utterance crossed the wire. The text itself never does — only how much of it there was,
    /// which is what a latency or truncation investigation actually needs.
    @discardableResult
    static func realtimeUtterance(_ provider: RealtimeProvider,
                                  direction: UtteranceDirection, characters: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeUtterance, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.direction, .token(PrivacyToken(direction.rawValue))),
            .init(.characters, .count(characters)),
        ]))
    }

    @discardableResult
    static func realtimeMedia(_ provider: RealtimeProvider, kind: RealtimeMediaKind,
                              kilobytes: Int, sequence: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.kind, .token(PrivacyToken(kind.rawValue))),
            .init(.kilobytes, .count(kilobytes)),
        ]
        if let sequence { fields.append(.init(.sequence, .count(sequence))) }
        return emit(.init(.realtime, .realtimeMedia, fields))
    }

    @discardableResult
    static func realtimeSendSkipped(_ provider: RealtimeProvider, kind: RealtimeSendKind,
                                    reason: RealtimeSkipReason, state: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.kind, .token(PrivacyToken(kind.rawValue))),
            .init(.reason, .token(PrivacyToken(reason.rawValue))),
        ]
        if let state { fields.append(.init(.state, .token(state))) }
        return emit(.init(.realtime, .realtimeSendSkipped, fields))
    }

    @discardableResult
    static func realtimeTruncated(_ provider: RealtimeProvider, item: String, playedMs: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeTruncated, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.item, .identifier(PrivateIdentifier(item))),
            .init(.duration, .milliseconds(playedMs)),
        ]))
    }

    @discardableResult
    static func realtimeReconnectScheduled(_ provider: RealtimeProvider,
                                           attempt: Int, of maxAttempts: Int, delaySeconds: Double) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeReconnectScheduled, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.attempt, .count(attempt)),
            .init(.ofAttempts, .count(maxAttempts)),
            .init(.delay, .seconds(delaySeconds)),
        ]))
    }

    /// The reconnect reason is deliberately absent: every caller derives it from an error's
    /// `localizedDescription`, which is user-content class.
    @discardableResult
    static func realtimeReconnectExhausted(_ provider: RealtimeProvider, attempts: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeReconnectExhausted, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.attempt, .count(attempts)),
        ]))
    }

    @discardableResult
    static func realtimeGoAway(_ provider: RealtimeProvider, secondsRemaining: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeGoAway, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.remaining, .count(secondsRemaining)),
        ]))
    }

    @discardableResult
    static func realtimeToolCall(_ provider: RealtimeProvider, functions: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeToolCall, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.count, .count(functions)),
        ]))
    }

    /// Call ids are private identifiers and there can be many, so the count is what is kept.
    @discardableResult
    static func realtimeToolCancellation(_ provider: RealtimeProvider, calls: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeToolCancellation, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.count, .count(calls)),
        ]))
    }

    @discardableResult
    static func realtimeLatency(_ provider: RealtimeProvider, milliseconds: Int) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeLatency, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.duration, .milliseconds(milliseconds)),
        ]))
    }

    @discardableResult
    static func realtimeError(_ provider: RealtimeProvider, phase: RealtimeErrorPhase,
                              _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.realtime, .realtimeError, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.phase, .token(PrivacyToken(phase.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }

    // MARK: - Capture

    /// What kind of thing the code held, never the thing itself.
    enum QRPayloadClass: String { case url, json, text }

    @discardableResult
    static func qrScanned(payload: QRPayloadClass, bytes: Int) -> PrivacyEvent {
        return emit(.init(.capture, .qrScanned, [
            .init(.payload, .token(PrivacyToken(payload.rawValue))),
            .init(.bytes, .count(bytes)),
        ]))
    }

    @discardableResult
    static func qrFetchBlocked(_ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.capture, .qrFetchBlocked, [
            .init(.error, .summary(summary)),
        ]))
    }

    /// The host is a private identifier (it names where the wearer was), so it is fingerprinted:
    /// enough to see two fetches went to the same place, not enough to say where.
    @discardableResult
    static func qrFetchLoaded(host: String?, characters: Int) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.characters, .count(characters))]
        if let host, !host.isEmpty {
            fields.insert(.init(.host, .identifier(PrivateIdentifier(host))), at: 0)
        }
        return emit(.init(.capture, .qrFetchLoaded, fields))
    }

    // MARK: - Cameras
    //
    // The camera plumbing is the one place in this batch where verbose logging earns its keep:
    // the DAT session/stream lifecycle is the hardest thing in the app to diagnose without a
    // device in hand, and states, capability transitions, resolutions and frame rates are all
    // public operation class. What a frame *shows* is not, and no method here takes a pixel, a
    // recognised string, or a user-facing notice — a compatibility notice and a camera-refusal
    // message are sentences composed for the wearer, so the event says which refusal it was.
    // The device id is a fingerprint: it names a particular pair of glasses on a particular face.

    /// Which camera. `privacyFilter` is the bystander-blur pass that sits between the glasses
    /// and every egress, and `decoder` is the video pipeline underneath both.
    enum CameraSource: String { case glasses, phone, decoder, privacyFilter }

    enum CameraEvent: String {
        case permissionRevalidating, registrationState, notRegistered
        case permissionRetry, permissionChecked, permissionFailed
        case sessionBound, sessionNotStarted, sessionError, sessionAttemptFailed
        case incompatibleDevice, capabilityCreated, capabilityTornDown, capabilityStopTimedOut
        case resolutionFloored, sessionReset, tornDown, idleTeardown
        case streamState, streamPausedWhileWanted, streamPausedAfterCapture
        case streamStoppedWhileWanted
        case reconnectScheduled, reconnectAttempt, reconnected, reconnectGaveUp
        case warmupAborted, warmupNudged, warmupSessionStopped, warmupAttemptFailed, warmupRetry
        case streamingReached, firstFrameTimedOut, waitAttemptFailed, streamError
        case started, stopped, suspended, resumed, unavailable, configured
        case frameReceived, frameStale, frameRejected, framePinned, framePinReleased
        case captureRequested, captureRejected, captureTimedOut, captureFallbackUsed
        case photoReceived, photoUnexpected, photoCaptured, photoNotSaved
        case stallDetected, stallRecovery, stallRecovered, stallRecoveryFailed
    }

    @discardableResult
    static func camera(_ source: CameraSource, _ event: CameraEvent,
                       device: PrivateIdentifier? = nil, state: PrivacyToken? = nil,
                       detail: PrivacyToken? = nil, resolution: PrivacyToken? = nil,
                       frameRate: Int? = nil, width: Int? = nil, height: Int? = nil,
                       attempt: Int? = nil, ofAttempts: Int? = nil, count: Int? = nil,
                       kilobytes: Int? = nil, bytes: Int? = nil, seconds: Double? = nil,
                       error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.source, .token(PrivacyToken(source.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let device { fields.append(.init(.device, .identifier(device))) }
        if let state { fields.append(.init(.state, .token(state))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let resolution { fields.append(.init(.resolution, .token(resolution))) }
        if let frameRate { fields.append(.init(.frameRate, .count(frameRate))) }
        if let width { fields.append(.init(.width, .count(width))) }
        if let height { fields.append(.init(.height, .count(height))) }
        if let attempt { fields.append(.init(.attempt, .count(attempt))) }
        if let ofAttempts { fields.append(.init(.ofAttempts, .count(ofAttempts))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let kilobytes { fields.append(.init(.kilobytes, .count(kilobytes))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.capture, .camera, fields))
    }

    /// Writes to the photo library. The album title is the app's own constant and the status is
    /// a system authorization state, so both are public; the asset is not described at all.
    enum PhotoLibraryEvent: String {
        case authorizationRequested, authorizationSettled, saveNotPermitted
        case saved, saveFailed, changeRequestUnbuildable
        case albumRetriedUntargeted, albumCreateFailed
    }

    enum PhotoLibraryAsset: String { case image, video }

    @discardableResult
    static func photoLibrary(_ event: PhotoLibraryEvent, asset: PhotoLibraryAsset? = nil,
                             status: PrivacyToken? = nil,
                             error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let asset { fields.append(.init(.kind, .token(PrivacyToken(asset.rawValue)))) }
        if let status { fields.append(.init(.state, .token(status))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.capture, .photoLibrary, fields))
    }

    // MARK: - Local recording
    //
    // A recording is the camera and the microphone written to a file, so the two things a
    // recording log is always tempted to name are exactly the two it may not: the *file*, whose
    // name is a session and a date and whose path is the sandbox, and the *transcript*, which is
    // the whole point of the auto-transcription pass. Geometry, frame rate, duration, frame and
    // buffer counts and the audio format are the shape of the pipeline and stay — a writer that
    // fails mid-file, or an audio format that changes underneath it, is diagnosed from those.

    enum RecordingEvent: String {
        case started, autoStopped, finished, filed, nothingOnDisk, fileFailed
        case writerFailed, noWriter
        case audioFormatChanged, audioBuffersDropped, audioAppendRejected
        case autoTranscriptionEnabled, transcriptCaptured, transcriptSaved, transcriptSaveFailed
    }

    /// `success` is whether the file reached the photo library; `count` is frames or buffers,
    /// `characters` is how long a transcript was. Neither the file nor the transcript has a
    /// parameter.
    @discardableResult
    static func recording(_ event: RecordingEvent, width: Int? = nil, height: Int? = nil,
                          frameRate: Int? = nil, count: Int? = nil, characters: Int? = nil,
                          seconds: Double? = nil, hertz: Int? = nil, channels: Int? = nil,
                          success: Bool? = nil, detail: PrivacyToken? = nil,
                          error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let width { fields.append(.init(.width, .count(width))) }
        if let height { fields.append(.init(.height, .count(height))) }
        if let frameRate { fields.append(.init(.frameRate, .count(frameRate))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let hertz { fields.append(.init(.hertz, .count(hertz))) }
        if let channels { fields.append(.init(.channels, .count(channels))) }
        if let success { fields.append(.init(.success, .flag(success))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.capture, .recording, fields))
    }

    // MARK: - Vision
    //
    // Everything these channels produce is content: OCR text is whatever the wearer pointed the
    // glasses at (a prescription, a bank statement, a letter), a narration is a description of
    // the room they are standing in, and a refusal notice is a sentence composed for them. So the
    // shape of the work survives — how many text blocks, how many characters, how long it took,
    // which gate refused — and none of the substance does.

    enum VisionChannel: String {
        case ocr, documentScan, sceneNarration, assistiveMode, navigationAssist
        case liveCoach, lookClosely, fingerspelling
    }

    enum VisionEvent: String {
        case started, stopped, halted, resumed, quieted, speakingAgain
        case refused, powerRefused, cameraClaimFailed
        case textRecognized, recognitionFailed, documentDetected, detectionFailed
        case frameInjected, captureTimedOut, captureFailed, declined
        case performanceSampled
    }

    /// `posture` is the power policy's own enum, `percent` is how much of the frame a detected
    /// document filled — both are measurements of the camera, not of what it saw.
    @discardableResult
    static func vision(_ channel: VisionChannel, _ event: VisionEvent,
                       reason: PrivacyToken? = nil, posture: PrivacyToken? = nil,
                       count: Int? = nil, characters: Int? = nil, percent: Int? = nil,
                       kilobytes: Int? = nil, milliseconds: Int? = nil,
                       extractionMilliseconds: Int? = nil, seconds: Double? = nil,
                       detail: PrivacyToken? = nil,
                       error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.channel, .token(PrivacyToken(channel.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let reason { fields.append(.init(.reason, .token(reason))) }
        if let posture { fields.append(.init(.posture, .token(posture))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let percent { fields.append(.init(.percent, .count(percent))) }
        if let kilobytes { fields.append(.init(.kilobytes, .count(kilobytes))) }
        if let milliseconds { fields.append(.init(.duration, .milliseconds(milliseconds))) }
        if let extractionMilliseconds {
            fields.append(.init(.extraction, .milliseconds(extractionMilliseconds)))
        }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.vision, .vision, fields))
    }

    // MARK: - Faces
    //
    // A recognised name is the single most identifying string this app ever holds, and the log
    // is the one sink that would keep it after the announcement has been spoken and forgotten.
    // There is no name parameter here — not even fingerprinted, because the enrolled set is a
    // handful of people and a stable hash of "the person seen most often" is an identifier in
    // everything but spelling. What is left is the fact of a match, how many candidates were in
    // contention, and how sure the matcher was, in three buckets.

    enum FaceEvent: String {
        case started, stopped, frequencyReduced, frequencyRestored
        case recognized, ambiguous
        case databaseLoaded, loadFailed, saveFailed
    }

    /// A coarse band, never the similarity itself: a raw score is a measurement of one person's
    /// face against one enrolment, and three of them in a row would characterise the enrolment.
    enum FaceConfidence: String {
        case low, medium, high

        init(similarity: Double) {
            switch similarity {
            case ..<0.7: self = .low
            case ..<0.85: self = .medium
            default: self = .high
            }
        }
    }

    @discardableResult
    static func face(_ event: FaceEvent, confidence: FaceConfidence? = nil,
                     candidates: Int? = nil, enrolled: Int? = nil,
                     error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let confidence { fields.append(.init(.confidence, .token(PrivacyToken(confidence.rawValue)))) }
        if let candidates { fields.append(.init(.count, .count(candidates))) }
        if let enrolled { fields.append(.init(.total, .count(enrolled))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.vision, .face, fields))
    }

    // MARK: - Home

    /// Operation classes, not commands. An entity id names a room and a device in someone's
    /// house; hashing it would not anonymise a dictionary that small, so it is simply omitted.
    enum HomeOperation: String {
        case converse, callService, getState, listEntities, runAutomation, toggle
    }

    enum HomeEntityMatch: String { case exact, fuzzy, unresolved }

    @discardableResult
    static func homeOperation(_ operation: HomeOperation, success: Bool,
                              replyCharacters: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
            .init(.success, .flag(success)),
        ]
        if let replyCharacters { fields.append(.init(.characters, .count(replyCharacters))) }
        return emit(.init(.home, .homeOperation, fields))
    }

    @discardableResult
    static func homeEntityResolved(_ match: HomeEntityMatch) -> PrivacyEvent {
        return emit(.init(.home, .homeEntityResolved, [
            .init(.match, .token(PrivacyToken(match.rawValue))),
        ]))
    }

    /// The direct call failed and the natural-language fallback is being tried. The command text
    /// is the fallback's whole payload and is never logged.
    @discardableResult
    static func homeFallback(_ operation: HomeOperation) -> PrivacyEvent {
        return emit(.init(.home, .homeFallback, [
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
        ]))
    }

    /// The plumbing beneath a home command: authorization, how many homes or entities the bridge
    /// can see, and whether the catalogue refreshed.
    ///
    /// A count of entities is a fact about the wearer's house too — it says roughly how large and
    /// how automated it is — but it is the one number that makes "the light didn't respond"
    /// diagnosable, and it names nothing. Accessory, room, scene and entity *names* are the
    /// regulated part and appear nowhere: they are a small, low-entropy dictionary, so they are
    /// omitted rather than hashed.
    enum HomeBridge: String { case homeKit, homeAssistant }

    enum HomeBridgeEvent: String {
        case managerInitialized, authorizationChanged, homesUpdated
        case homesUnavailable, homesTimedOut, waitingForHomes
        case readBeforeWriteFailed
        case notConfigured, catalogueRefreshed, catalogueFetchFailed, catalogueParseFailed
    }

    @discardableResult
    static func homeBridge(_ bridge: HomeBridge, _ event: HomeBridgeEvent,
                           status: Int? = nil, count: Int? = nil, attempt: Int? = nil,
                           error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.provider, .token(PrivacyToken(bridge.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let status { fields.append(.init(.status, .count(status))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let attempt { fields.append(.init(.attempt, .count(attempt))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.home, .homeBridge, fields))
    }

    // MARK: - Medical
    //
    // The regulated row of the classification table, at its strictest. A clinical value, a
    // medication name, a condition, an export body and a protected file's *name* (which is
    // frequently a date and a patient) all have no parameter here.
    //
    // `HIPAAComplianceService`'s audit trail is a separate, deliberate store with its own
    // retention and export path — it keeps action and detail on purpose. What is migrated here is
    // only its debug mirror, which copied every audit line into the device log where none of that
    // protection applies. The action class survives (it is a fixed vocabulary of operation names);
    // the detail does not.

    enum MedicalSubsystem: String {
        case compliance, audit, export, fhir, safetyAssessment, healthSafety, fitness
    }

    enum MedicalEvent: String {
        case fileProtected, fileProtectionFailed
        case auditRecorded, auditLoadFailed, auditSaveFailed
        case retentionPurged, purgeFailed
        case exportFailed, exportUnsupported
        case credentialsMigrated, migrationDeferred, migrationFailed, migrationUnverified
        case saveSkipped, persistFailed
        case citationsWithheld, workoutSaveFailed
    }

    @discardableResult
    static func medical(_ subsystem: MedicalSubsystem, _ event: MedicalEvent,
                        operation: PrivacyToken? = nil, count: Int? = nil, days: Int? = nil,
                        error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.subsystem, .token(PrivacyToken(subsystem.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let operation { fields.append(.init(.operation, .token(operation))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let days { fields.append(.init(.days, .count(days))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.medical, .medical, fields))
    }

    // MARK: - Location
    //
    // Coordinates, a reverse-geocoded place, a geofence's name and a region identifier are all
    // regulated: together they are the wearer's movements. A geofence event is that it fired and
    // which way; how many are armed is the only number a monitoring fault needs.

    enum LocationEvent: String {
        case authorized, denied, updateFailed, placeResolved
        case regionMonitoringFailed, geofencesRestored, geofenceEntered, geofenceExited
        case rerouteFailed, routeStartFailed
    }

    @discardableResult
    static func location(_ event: LocationEvent, count: Int? = nil,
                         error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let count { fields.append(.init(.count, .count(count))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.location, .location, fields))
    }

    // MARK: - Lifecycle / inbound links

    /// Which door was knocked on. Never the URL: a callback URL carries auth codes in its query,
    /// and a universal link carries the host the wearer came from.
    enum DeepLinkRoute: String {
        case shortcutCallback, skillPack, persona, connect, capture, listen, quickAction
        case wearablesCallback, other
    }

    enum DeepLinkVerdict: String {
        case received, accepted, untrusted, malformed, sdkUnavailable, handled, failed
    }

    @discardableResult
    static func deepLink(route: DeepLinkRoute, source: PrivacyToken, verdict: DeepLinkVerdict,
                         action: PrivacyToken? = nil, error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.route, .token(PrivacyToken(route.rawValue))),
            .init(.source, .token(source)),
            .init(.verdict, .token(PrivacyToken(verdict.rawValue))),
        ]
        if let action { fields.append(.init(.action, .token(action))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.lifecycle, .deepLink, fields))
    }

    /// The proactive alerter's own lifecycle, and the fact that it spoke.
    ///
    /// The alert text is built from a calendar entry — "leave for your appointment with
    /// Dr Alvarez in 10 minutes" — and was being written to the log in full on every delivery,
    /// alongside the event title whenever an agenda produced a playbook. Both are user content;
    /// how long the alert was, and how many steps the agenda had, are not.
    enum ProactiveAlertEvent: String {
        case started, stopped, paused, resumed, delivered, playbookCreated
    }

    @discardableResult
    static func proactiveAlert(_ event: ProactiveAlertEvent, characters: Int? = nil,
                               count: Int? = nil, seconds: Double? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        return emit(.init(.lifecycle, .proactiveAlert, fields))
    }

    // MARK: - Auth

    enum AuthProvider: String { case claude, chatgpt, google }
    enum AuthOperation: String { case tokenRefresh }

    @discardableResult
    static func authFailed(_ provider: AuthProvider, _ operation: AuthOperation,
                           _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.auth, .authFailed, [
            .init(.provider, .token(PrivacyToken(provider.rawValue))),
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }

    /// Which keychain access failed, and with which `OSStatus`.
    ///
    /// The key *name* is deliberately absent. It is drawn from a small fixed dictionary of
    /// provider names, so hashing it would not anonymise anything (the plan says as much), and
    /// naming it in a log would say which credentials this wearer holds. The operation plus the
    /// status is what a keychain fault is actually diagnosed from.
    enum KeychainOperation: String { case read, write }

    @discardableResult
    static func keychainFailed(_ operation: KeychainOperation, status: Int) -> PrivacyEvent {
        return emit(.init(.auth, .keychainFailed, [
            .init(.operation, .token(PrivacyToken(operation.rawValue))),
            .init(.status, .count(status)),
        ]))
    }

    /// A one-time move of stored configuration. Never what moved — only that it did.
    enum ConfigMigration: String { case providerSecrets, gatewayConfig }
    enum MigrationOutcome: String { case completed, deferred }

    @discardableResult
    static func configMigration(_ migration: ConfigMigration, _ outcome: MigrationOutcome) -> PrivacyEvent {
        return emit(.init(.auth, .configMigration, [
            .init(.migration, .token(PrivacyToken(migration.rawValue))),
            .init(.outcome, .token(PrivacyToken(outcome.rawValue))),
        ]))
    }

    // MARK: - Gateway
    //
    // Everything about the gateway link is either a state transition or an identifier. The
    // endpoint itself never appears: a LAN URL names the wearer's home network and a tunnel URL
    // names their host, and both are routinely presented alongside a bearer token. `LogRedaction`
    // used to stand in for this — it masks two token shapes and nothing else, which is why the
    // four sites that called it are migrated here rather than kept.

    /// Which leg of the link is in use. Not *which* host — only LAN versus remote.
    enum GatewayTransport: String { case lan, tunnel, unknown }

    enum GatewayConnectionEvent: String {
        case notConfigured, inactive
        case endpointResolved, endpointUnreachable, endpointCacheDropped, endpointMalformed, failover
        case connecting, connected, disconnected, reconnectScheduled
        case challengeReceived, handshakeSent, authRejected
        case sessionRotated, sessionCompacted
        case devicePaired, pairingPending
        case deviceEventSent
        /// hello-ok parsed: `count` is the size of the advertised catalog, `detail` the granted role.
        case helloReceived
    }

    /// `peer` is which gateway — a private identifier, so it is fingerprinted: enough to tell two
    /// gateways apart across a failover, not enough to name either or say where it lives.
    @discardableResult
    static func gatewayConnection(_ event: GatewayConnectionEvent,
                                  transport: GatewayTransport? = nil,
                                  peer: PrivateIdentifier? = nil,
                                  count: Int? = nil,
                                  detail: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let transport { fields.append(.init(.transport, .token(PrivacyToken(transport.rawValue)))) }
        if let peer { fields.append(.init(.peer, .identifier(peer))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        return emit(.init(.gateway, .gatewayConnection, fields))
    }

    @discardableResult
    static func gatewayReconnectScheduled(delaySeconds: Double) -> PrivacyEvent {
        return emit(.init(.gateway, .gatewayConnection, [
            .init(.event, .token(PrivacyToken(GatewayConnectionEvent.reconnectScheduled.rawValue))),
            .init(.delay, .seconds(delaySeconds)),
        ]))
    }

    /// The health probe's verdict. The probe's response body was previously logged whole; a
    /// gateway body carries session titles and agent output, so only the status survives.
    @discardableResult
    static func gatewayHealth(_ transport: GatewayTransport, reachable: Bool,
                              status: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.transport, .token(PrivacyToken(transport.rawValue))),
            .init(.success, .flag(reachable)),
        ]
        if let status { fields.append(.init(.status, .count(status))) }
        return emit(.init(.gateway, .gatewayHealth, fields))
    }

    enum GatewayOutcome: String { case succeeded, rejected, unsupported, failed }

    /// A protocol call: `sessions.send`, `cron.create`, `tools.available`. The method name is a
    /// fixed vocabulary defined by the protocol, so it is public operation class. Its params and
    /// its result are the task text and the agent's answer, so neither has a parameter here —
    /// `characters` is how much came back, which is what a truncation report needs.
    @discardableResult
    static func gatewayOperation(_ method: String, outcome: GatewayOutcome,
                                 count: Int? = nil, characters: Int? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.method, .token(PrivacyToken(method))),
            .init(.outcome, .token(PrivacyToken(outcome.rawValue))),
        ]
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        return emit(.init(.gateway, .gatewayOperation, fields))
    }

    /// An unsolicited push from the gateway. The preview text *is* the notification — it is read
    /// aloud to the wearer — so its length is the only thing recorded.
    enum GatewayNotificationKind: String { case heartbeat, cronResult, triage, lateResult }

    @discardableResult
    static func gatewayNotification(_ kind: GatewayNotificationKind, characters: Int) -> PrivacyEvent {
        return emit(.init(.gateway, .gatewayNotification, [
            .init(.kind, .token(PrivacyToken(kind.rawValue))),
            .init(.characters, .count(characters)),
        ]))
    }

    enum GatewayPhase: String { case health, handshake, receive, send, request }

    @discardableResult
    static func gatewayFailed(_ phase: GatewayPhase, _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.gateway, .gatewayFailed, [
            .init(.phase, .token(PrivacyToken(phase.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }

    // MARK: - MCP

    /// Server labels are user-chosen and often name an employer or a household, so they are
    /// fingerprinted. Tool names are the protocol's public vocabulary and are kept as tokens.
    @discardableResult
    static func mcpDiscovery(tools: Int, servers: Int) -> PrivacyEvent {
        return emit(.init(.mcp, .mcpDiscovery, [
            .init(.count, .count(tools)),
            .init(.servers, .count(servers)),
        ]))
    }

    /// A discovery-time trust verdict. The scanner's `reason` is free-form prose built from an
    /// attacker-authored tool description, so the verdict is kept and the reason is not.
    enum MCPToolVerdict: String { case blocked, quarantined }

    @discardableResult
    static func mcpToolScreened(_ verdict: MCPToolVerdict, tool: String,
                                server: PrivateIdentifier) -> PrivacyEvent {
        return emit(.init(.mcp, .mcpToolScreened, [
            .init(.verdict, .token(PrivacyToken(verdict.rawValue))),
            .init(.tool, .token(PrivacyToken(tool))),
            .init(.server, .identifier(server)),
        ]))
    }

    /// An outbound egress-screen decision. The pattern names that fired describe the *content*
    /// that was about to leave, so the count goes to the log and the names stay in the trust UI.
    enum MCPEgressAction: String { case allowed, redacted, blocked }

    @discardableResult
    static func mcpEgress(_ action: MCPEgressAction, tool: String, server: PrivateIdentifier,
                          hits: Int) -> PrivacyEvent {
        return emit(.init(.mcp, .mcpEgress, [
            .init(.action, .token(PrivacyToken(action.rawValue))),
            .init(.tool, .token(PrivacyToken(tool))),
            .init(.server, .identifier(server)),
            .init(.count, .count(hits)),
        ]))
    }

    enum MCPPhase: String { case discovery, transport, sessionInit }

    @discardableResult
    static func mcpFailed(_ phase: MCPPhase, server: PrivateIdentifier,
                          _ summary: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.phase, .token(PrivacyToken(phase.rawValue))),
            .init(.server, .identifier(server)),
        ]
        if let summary { fields.append(.init(.error, .summary(summary))) }
        return emit(.init(.mcp, .mcpFailed, fields))
    }

    /// The local server we expose on the LAN.
    enum MCPServerEvent: String {
        case listening, stopped, startFailed, requestRejected, forwardUnsupported
    }

    /// The request path is classified rather than quoted: it arrives from the network, so an
    /// unknown path is attacker-supplied text.
    enum MCPRoute: String { case seeGlasses, glassesStatus, sendToGlasses, unknown }

    @discardableResult
    static func mcpServer(_ event: MCPServerEvent, port: Int? = nil, route: MCPRoute? = nil,
                          error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let port { fields.append(.init(.port, .count(port))) }
        if let route { fields.append(.init(.route, .token(PrivacyToken(route.rawValue)))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.mcp, .mcpServer, fields))
    }

    // MARK: - Streams

    /// Which outbound link. A room URL is a bearer capability — anyone holding it watches the
    /// wearer's camera — so no method here accepts one.
    /// `broadcastChat` is the inbound half of a live broadcast. Chat messages are written by
    /// strangers *about* the wearer and read aloud into their ear; the channel name identifies
    /// the wearer's own broadcast account. Neither has a parameter — the channel arrives as a
    /// `session` fingerprint and a message only ever as a count.
    ///
    /// `rtmpBroadcast` is the sharpest of the five. An RTMP destination is an ingest URL plus a
    /// **stream key**, and the key is a bearer credential: anyone holding it can publish as the
    /// wearer, to the wearer's own channel, for as long as it is not rotated. Neither half has a
    /// parameter here — not the URL, not the key, not a prefix of the key, and not the stall
    /// policy's advice sentence, which is composed *around* the destination URL.
    enum StreamChannel: String {
        case viewerBroadcast, expertBridge, hudMirror, signaling, broadcastChat, rtmpBroadcast
    }

    enum StreamEvent: String {
        case started, stopped, listening, startFailed
        case viewerJoined, viewerLeft
        case expertPaged, expertBridgeUnavailable
        case negotiationFailed, sendFailed, receiveFailed
        case joined, connectionLost, reconnectScheduled
        case connecting, connected, publishing, reconnected, reconnectFailed, failed, stalled
        case encoderConfigured, encoderPrimed, audioAttached, audioUnavailable
        case sourceSwitched, bitrateAdjusted
    }

    /// Geometry, frame rate, bitrate and queue depth are the whole diagnostic vocabulary of a
    /// live encoder and are public operation class. `detail` carries a source kind or a state,
    /// never a destination.
    @discardableResult
    static func stream(_ channel: StreamChannel, _ event: StreamEvent,
                       detail: PrivacyToken? = nil, count: Int? = nil,
                       session: PrivateIdentifier? = nil, attempt: Int? = nil,
                       delaySeconds: Double? = nil, seconds: Double? = nil,
                       width: Int? = nil, height: Int? = nil, frameRate: Int? = nil,
                       bitrate: Int? = nil, measuredBitrate: Int? = nil, bytes: Int? = nil,
                       error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.channel, .token(PrivacyToken(channel.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let session { fields.append(.init(.session, .identifier(session))) }
        if let attempt { fields.append(.init(.attempt, .count(attempt))) }
        if let delaySeconds { fields.append(.init(.delay, .seconds(delaySeconds))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let width { fields.append(.init(.width, .count(width))) }
        if let height { fields.append(.init(.height, .count(height))) }
        if let frameRate { fields.append(.init(.frameRate, .count(frameRate))) }
        if let bitrate { fields.append(.init(.bitrate, .count(bitrate))) }
        if let measuredBitrate { fields.append(.init(.measuredBitrate, .count(measuredBitrate))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.stream, .stream, fields))
    }

    // MARK: - Speech in
    //
    // Everything the wearer says is user content, and a wake-word listener hears it continuously
    // whether or not it was addressed. What is left after the words are removed still describes
    // the subsystem completely: which engine ran, which direction audio was flowing, how much of
    // it there was, and what failed.

    /// Wake-word detection is an event, not a phrase.
    ///
    /// The matched phrase, the transcript it sat in, the persona names and the contextual-boost
    /// list are all user content or wearer-authored configuration — a wake phrase is usually a
    /// name — so none of them has a parameter here. `distance` is the fuzzy matcher's edit
    /// distance: a small integer confidence bucket, not a fragment of what was heard.
    enum WakeEvent: String {
        case listenerStarted, listenerSkippedPushToTalk, listenAttemptFailed
        case onDeviceUnavailable, contextConfigured
        case detected, fuzzyDetected, bargeIn, stopCommand
        case recognitionFailed, sustainedSilence, audioResumed
    }

    /// What interrupted the assistant mid-sentence: the wake phrase again, or simply the fact
    /// that the wearer had started talking.
    enum BargeInTrigger: String { case wakePhrase, voiceActivity }

    @discardableResult
    static func wakeWord(_ event: WakeEvent, trigger: BargeInTrigger? = nil,
                         attempt: Int? = nil, count: Int? = nil, distance: Int? = nil,
                         error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let trigger { fields.append(.init(.kind, .token(PrivacyToken(trigger.rawValue)))) }
        if let attempt { fields.append(.init(.attempt, .count(attempt))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let distance { fields.append(.init(.distance, .count(distance))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.speech, .wakeWord, fields))
    }

    /// Which listener produced the transcript. Naming the channel is what makes a caption-path
    /// fault distinguishable from a dictation-path fault without quoting either transcript.
    enum SpeechChannel: String {
        case dictation, onDeviceASR, ambientCaptions, liveTranslation, meetingNotes
        case memoryRewind, diarization, intentClassifier
    }

    enum SpeechEvent: String {
        case started, stopped, suspended, resumed, reconfigured
        case recognizerUnavailable, engineShared, engineDedicated, engineRebuilt
        case engineFailed, sessionFailed
        case transcriptDelivered, noSpeechDetected, recognitionFailed
        case artifactDropped, silenceGated, noteInserted
        case translated, translationUnavailable, providerUnavailable
        case sendFailed, analysisCompleted
    }

    /// `language` is a BCP-47 tag — a property of the session, not of what was said — so it is
    /// public operation class. `characters` is how long the transcript was; the transcript has no
    /// parameter, and neither does the artifact filter's rejected text (it is a transcript that
    /// merely failed a quality check, which does not make it any less what the wearer said).
    @discardableResult
    static func speech(_ channel: SpeechChannel, _ event: SpeechEvent,
                       language: PrivacyToken? = nil, characters: Int? = nil,
                       count: Int? = nil, seconds: Double? = nil, bytes: Int? = nil,
                       detail: PrivacyToken? = nil,
                       error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.channel, .token(PrivacyToken(channel.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let language { fields.append(.init(.language, .token(language))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.speech, .speech, fields))
    }

    // MARK: - Speech out

    enum TTSEvent: String {
        case speaking, finished, cancelled, suppressed, staleGeneration, discarded
        case engineFailed, engineFallback
        case requested, received, playing, playbackFinished, decodeFailed
        case voiceSelected, quotaExhausted, quotaCacheReset, toneFailed, voicesRequestFailed
    }

    /// The spoken text is the assistant answering the wearer — the other half of the transcript,
    /// and no less private for having been generated — so only its length survives. A voice id
    /// identifies a purchased or cloned voice and is fingerprinted; the engine that rendered it,
    /// and the fallback chain it belongs to, are public operation class.
    @discardableResult
    static func tts(_ event: TTSEvent, engine: PrivacyToken? = nil, characters: Int? = nil,
                    bytes: Int? = nil, seconds: Double? = nil, quality: Int? = nil,
                    voice: PrivateIdentifier? = nil, status: Int? = nil, success: Bool? = nil,
                    detail: PrivacyToken? = nil,
                    error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let engine { fields.append(.init(.engine, .token(engine))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let quality { fields.append(.init(.quality, .count(quality))) }
        if let voice { fields.append(.init(.voice, .identifier(voice))) }
        if let status { fields.append(.init(.status, .count(status))) }
        if let success { fields.append(.init(.success, .flag(success))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.speech, .tts, fields))
    }

    // MARK: - Audio plumbing
    //
    // Route, format and interruption events are public operation class, and this app's audio
    // graph is genuinely hard to diagnose without them — half the hard-won behaviour in the
    // capture path was found by reading these lines off a device. Port *names* are the exception:
    // "Greig's Ray-Ban Meta" names a person and their hardware, so a device is a fingerprint
    // while its port *type* (`BluetoothLE`, `BuiltInMic`) is a token.

    enum AudioSubsystem: String {
        case wakeWord, realtime, coordinator, captureTap, captureRouter
        case recording, translation, backgroundVoice, session
    }

    enum AudioEvent: String {
        case sessionConfigured, sessionConfigureFailed, sessionFallbackActivated
        case sessionReleased, sessionDeactivated, sessionAcquireFailed
        case otherAudioPaused, otherAudioResumed, otherAudioHeld, pauseSkippedActiveCall
        case routeChanged, preferredInputSet, preferredInputFailed, noMatchingInput
        case interruptionBegan, interruptionEnded, interruptionEndedNotResuming
        case resumed, resumeFailed, resetSucceeded, resetFailed
        case engineStarted, engineStopped, engineReused, engineRebuilt, engineRestarted
        case engineRestartFailed, engineRestartedDeaf, engineStartFailed
        case formatInvalid, formatNegotiated, conversionFailed
        case deviceDisconnected, deviceReconnected, deviceIgnored
        case playbackDropped, playbackCarried, playbackDiscarded
        case voiceProcessingFailed, voiceProcessingDead
        case captureStarted, clientVoiceInterrupt, modeSelected
        case leaseHeld, leaseAssumed, leaseAcquired, leaseReleased
        case leaseStale, leaseSuppressed, leaseDeactivateFailed
        case callReported, callFailed, callAnswered, callEnded, providerReset
    }

    @discardableResult
    static func audio(_ subsystem: AudioSubsystem, _ event: AudioEvent,
                      owner: PrivacyToken? = nil, route: PrivacyToken? = nil,
                      device: PrivateIdentifier? = nil, detail: PrivacyToken? = nil,
                      hertz: Int? = nil, channels: Int? = nil, bytes: Int? = nil,
                      milliseconds: Int? = nil, count: Int? = nil,
                      error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.subsystem, .token(PrivacyToken(subsystem.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let owner { fields.append(.init(.owner, .token(owner))) }
        if let route { fields.append(.init(.route, .token(route))) }
        if let device { fields.append(.init(.device, .identifier(device))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let hertz { fields.append(.init(.hertz, .count(hertz))) }
        if let channels { fields.append(.init(.channels, .count(channels))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let milliseconds { fields.append(.init(.duration, .milliseconds(milliseconds))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.audio, .audio, fields))
    }

    // MARK: - Models
    //
    // A model *id* (`claude-opus-4`, `gemini-2.0-flash`) is a public catalog name and stays a
    // token. A model *configuration name* is typed by the wearer — "Work Claude", "Clinic
    // summariser" — so it is fingerprinted. Prompts, reasoning traces, completions, tool
    // arguments and server error bodies have no parameter at all: the whole turn is user content
    // and the useful diagnostics are its shape, not its substance.

    enum ModelEvent: String {
        case turnStarted, turnCompleted, requestSent
        case historyLoaded, historyCleared, compressionFailed
        case planLoopEmpty, planLoopCompleted, cascadeSwitched
        case apiError, streamError, streamRetry, requestFailed
        case toolCallsParsed, toolCallDropped, toolsPayloadRejected, yieldedToHuman
        case emptyCompletion, imageSkipped, reasoningProduced
        case agentSelected, catalogDiscovered, catalogUnavailable
        case classified, classificationFailed, analysisCompleted
    }

    /// How an utterance was classified. The utterance itself, and the classifier's free-form
    /// answer when it did not fit the vocabulary, are both user content.
    enum ModelClassification: String { case respond, ignore, uncertain }

    @discardableResult
    static func model(_ event: ModelEvent, provider: PrivacyToken? = nil,
                      model: PrivacyToken? = nil, configuration: PrivateIdentifier? = nil,
                      attempt: Int? = nil, count: Int? = nil, total: Int? = nil,
                      characters: Int? = nil, tokens: Int? = nil, status: Int? = nil,
                      bytes: Int? = nil, seconds: Double? = nil, success: Bool? = nil,
                      detail: PrivacyToken? = nil,
                      error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let provider { fields.append(.init(.provider, .token(provider))) }
        if let model { fields.append(.init(.model, .token(model))) }
        if let configuration { fields.append(.init(.configuration, .identifier(configuration))) }
        if let attempt { fields.append(.init(.attempt, .count(attempt))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let total { fields.append(.init(.total, .count(total))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let tokens { fields.append(.init(.tokens, .count(tokens))) }
        if let status { fields.append(.init(.status, .count(status))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let success { fields.append(.init(.success, .flag(success))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.model, .model, fields))
    }

    /// History compaction, which is the one model event whose whole point is a before/after pair.
    /// Four counts and a preserved-signal count say everything a compaction bug needs; the
    /// messages that were dropped or summarised are the conversation itself.
    @discardableResult
    static func modelCompaction(messagesBefore: Int, messagesAfter: Int,
                                tokensBefore: Int, tokensAfter: Int,
                                signals: Int? = nil, detail: PrivacyToken? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.messagesBefore, .count(messagesBefore)),
            .init(.messagesAfter, .count(messagesAfter)),
            .init(.tokensBefore, .count(tokensBefore)),
            .init(.tokensAfter, .count(tokensAfter)),
        ]
        if let signals { fields.append(.init(.signals, .count(signals))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        return emit(.init(.model, .modelCompaction, fields))
    }

    /// On-device inference. Model ids here are catalog ids from the app's own model list, so they
    /// are public; the generated text, the prompt it answered and the tool arguments it produced
    /// are not. Memory figures are the reason these lines exist at all — an MLX model that will
    /// not load is diagnosed from footprint, not from what it was asked.
    enum LocalModelEvent: String {
        case downloaded, downloadCancelled, deleted, tempsSwept
        case loaded, loadFailed, unloaded, visionDemoted, imageRefused
        case generationStarted, generationCompleted, generationFailed, stalled
        /// The prompt finished its batched prefill. Separate from `generationStarted` because
        /// prefill time and first-token latency are different diagnostics with different causes.
        case promptDecoded
        case historyTrimmed, toolCall, reasoningProduced, tokenShape
        /// Installed-model records (Plan DZ P0). These carry **counts only** — a compatibility
        /// descriptor's id is whatever the user typed into the model field, which makes it
        /// user-authored text rather than a public catalog token.
        case recordsMigrated, recordsMigrationDeferred, recordsMigrationFailed
        /// Acquisition pipeline. A *curated* plan names its catalog id, which is a public token; an
        /// **imported** plan names nothing — the repository the user typed is user content, and the
        /// `detail` field carries the plan's origin instead, so a log reader can still tell the two
        /// pipelines apart without the line naming anyone's repository.
        case downloadPlanned, downloadStarted, downloadRecovered, downloadFailed, installCompleted
    }

    /// `shape` is the prompt tensor's dimensions rendered as `1x842` — the diagnostic that
    /// distinguishes a text-factory model fed a batched tensor (a fatal Metal crash) from a
    /// correct load. It is numbers about the prompt, never any of it.
    @discardableResult
    static func localModel(_ event: LocalModelEvent, model: PrivacyToken? = nil,
                           vision: Bool? = nil, count: Int? = nil, total: Int? = nil,
                           characters: Int? = nil, tokens: Int? = nil, shape: PrivacyToken? = nil,
                           megabytes: Int? = nil, cacheMegabytes: Int? = nil,
                           footprintMegabytes: Int? = nil, headroomMegabytes: Int? = nil,
                           kilobytes: Int? = nil,
                           tool: PrivacyToken? = nil, detail: PrivacyToken? = nil,
                           milliseconds: Int? = nil, firstTokenMilliseconds: Int? = nil,
                           percent: Int? = nil, state: PrivacyToken? = nil,
                           error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let model { fields.append(.init(.model, .token(model))) }
        if let vision { fields.append(.init(.vision, .flag(vision))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let total { fields.append(.init(.total, .count(total))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let tokens { fields.append(.init(.tokens, .count(tokens))) }
        if let shape { fields.append(.init(.shape, .token(shape))) }
        if let megabytes { fields.append(.init(.megabytes, .count(megabytes))) }
        if let cacheMegabytes { fields.append(.init(.cacheMegabytes, .count(cacheMegabytes))) }
        if let footprintMegabytes {
            fields.append(.init(.footprintMegabytes, .count(footprintMegabytes)))
        }
        if let headroomMegabytes {
            fields.append(.init(.headroomMegabytes, .count(headroomMegabytes)))
        }
        if let kilobytes { fields.append(.init(.kilobytes, .count(kilobytes))) }
        if let tool { fields.append(.init(.tool, .token(tool))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let milliseconds { fields.append(.init(.duration, .milliseconds(milliseconds))) }
        if let firstTokenMilliseconds {
            fields.append(.init(.elapsed, .milliseconds(firstTokenMilliseconds)))
        }
        if let percent { fields.append(.init(.percent, .count(percent))) }
        if let state { fields.append(.init(.state, .token(state))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.model, .localModel, fields))
    }

    // MARK: - Conversation history

    /// Which store. Both hold text the wearer wrote or spoke, which is why they share a category.
    enum ContentStore: String { case conversations, teleprompterScripts }

    /// Thread titles and message bodies are the conversation itself. A thread *id* is a private
    /// identifier and is fingerprinted — enough to follow one thread across a session's log,
    /// not enough to name it. Persona/project ids are omitted rather than hashed: the set is
    /// small and wearer-visible, so a fingerprint would not anonymise which persona was in use.
    enum ConversationEvent: String {
        case sessionRestored, threadStarted, threadEnded, threadResumed, summaryUpdated
        case threadsDeleted
        case loaded, recovered, saveSkipped, saveFailed
        case encryptionEnabled, encryptionDisabled, encryptionFailed
        case unlockFailed, locked, awaitingAuthentication
        case keyCreated, keyDeleted, fileEncrypted
    }

    @discardableResult
    static func conversation(_ store: ContentStore, _ event: ConversationEvent,
                             thread: PrivateIdentifier? = nil, count: Int? = nil,
                             characters: Int? = nil, minutes: Int? = nil,
                             detail: PrivacyToken? = nil,
                             error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.store, .token(PrivacyToken(store.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let thread { fields.append(.init(.thread, .identifier(thread))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let minutes { fields.append(.init(.minutes, .count(minutes))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.conversation, .conversation, fields))
    }

    // MARK: - Persistence
    //
    // A store's *role* is public — there are seventeen of them and the set is fixed in this file,
    // so saying which one failed is how a persistence fault is diagnosed at all. Everything a
    // store holds is not: a memory key and its value are the facts the wearer asked to be
    // remembered, a diary line is what the agent wrote about their day, a document name is the
    // title of something they scanned, and a *filename* is frequently one of those titles with an
    // extension on it. So no method here takes a path, a name, a key, or a record.
    //
    // The salvage paths are the sharp edge and the reason this section is worded so tightly.
    // `JSONStore` backs up a blob it could not decode and then salvages what it can, and the
    // useful facts are which slot, how many records survived and how many were in the file. The
    // decode error is not one of them: a `DecodingError`'s description quotes the JSON it choked
    // on, which is the record. `SafeErrorSummary` reduces it to a case name and a coding-path
    // *depth* — never a key name, because a dictionary's keys are data.

    /// Which store. Roles, not files — every one of these is a fixed slot in the app, and a store
    /// whose name came from the wearer would have to be fingerprinted instead.
    ///
    /// `jsonBlob` is the shared load/salvage helper the JSON-backed stores route through; the slot
    /// it was working on arrives as `slot`, and a test pins that every call site passes a literal
    /// from a fixed set rather than a value.
    enum StoreName: String {
        case jsonBlob
        case semanticMemory, brain, ragDocuments, agentDocuments
        case conversationIndex, conversationRecall
        case evolvedSkills, usage, playbooks, operationJournal
        case readingSessions, studyDecks, recordedSessions, skillPacks, skillHub
        case offlineQueue, homeGrid
    }

    /// Which pool a memory belongs to. The namespace behind this is a persona id — a small,
    /// wearer-visible set — so which *pool* was written survives and which persona does not, per
    /// the plan's rule against hashing a low-entropy dictionary.
    enum StoreScope: String { case global, persona }

    enum StoreEvent: String {
        case opened, openFailed, queryFailed
        case loadFailed, readFailed, unreadablePreserved, preserveFailed
        case saved, saveFailed, saveSkipped
        case backedUp, backupFailed, salvaged, blobUndecodable
        case recordWritten, writeFailed, cleared, evicted, deleteFailed
        case migrated, legacyRetired, legacyRetireFailed
        case ingested, reembedded, appended, recovered
    }

    @discardableResult
    static func store(_ store: StoreName, _ event: StoreEvent,
                      slot: PrivacyToken? = nil, scope: StoreScope? = nil,
                      count: Int? = nil, total: Int? = nil, characters: Int? = nil,
                      bytes: Int? = nil, detail: PrivacyToken? = nil,
                      error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.store, .token(PrivacyToken(store.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let slot { fields.append(.init(.slot, .token(slot))) }
        if let scope { fields.append(.init(.scope, .token(PrivacyToken(scope.rawValue)))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let total { fields.append(.init(.total, .count(total))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.store, .store, fields))
    }

    // MARK: - Import / export / sync
    //
    // The boundary crossings. A manifest count, a format class, a byte size and a retry tier are
    // public; an entry name, an archive path and a queued operation's payload are not.
    //
    // Skill identity is the judgement call here and it goes the strict way: a hub skill's slug and
    // a pack's id are community-authored, chosen by whoever published them and installed because
    // the wearer went looking for that subject, so they are fingerprinted rather than kept. The
    // *version* stays a token — it is published metadata that says nothing about who installed it.

    enum TransferChannel: String {
        case skillPack, skillHub, agentExport, recordingFile, spotlightIndex, offlineSync
        /// The out-of-process `URLSession` the model hub downloads through. Its session
        /// identifier is app-chosen and its file is a model weight, so neither is named.
        case backgroundDownload
        /// The wearer exporting the diagnostic ring. The bundle's own contents are structured
        /// events that were already logged, so the lifecycle is what is recorded here: a lease
        /// made, shared, released, or scavenged after a crash. Never the file, never its bytes.
        case diagnosticsExport
    }

    enum TransferEvent: String {
        case installed, removed, imported, quarantined, catalogueEmpty
        case exported
        case fileFailed, copyFailed
        case donationFailed, purgeFailed
        case attemptsExhausted, permanentlyFailed
        case sessionResumed, sessionCompleted
        case shareStarted, shareEnded, released, scavenged
    }

    /// `operation` is a queued op's kind — `OfflineQueue.OpKind`, a fixed enum — and never its
    /// payload. `item` is an op id or a skill identity, fingerprinted. The sink's failure `reason`
    /// is free-form prose composed by whatever refused the operation, so it has no parameter.
    @discardableResult
    static func transfer(_ channel: TransferChannel, _ event: TransferEvent,
                         item: PrivateIdentifier? = nil, version: PrivacyToken? = nil,
                         operation: PrivacyToken? = nil, signed: Bool? = nil,
                         count: Int? = nil, total: Int? = nil, attempt: Int? = nil,
                         bytes: Int? = nil,
                         error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.channel, .token(PrivacyToken(channel.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let item { fields.append(.init(.item, .identifier(item))) }
        if let version { fields.append(.init(.version, .token(version))) }
        if let operation { fields.append(.init(.operation, .token(operation))) }
        if let signed { fields.append(.init(.signed, .flag(signed))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let total { fields.append(.init(.total, .count(total))) }
        if let attempt { fields.append(.init(.attempt, .count(attempt))) }
        if let bytes { fields.append(.init(.bytes, .count(bytes))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.transfer, .transfer, fields))
    }

    // MARK: - Devices and surfaces
    //
    // The glasses link is the app's central operational fact and the reason most of these lines
    // exist: "the Connect button does nothing" is diagnosed from registration states, device-list
    // transitions and Bluetooth route changes, none of which describe the wearer.
    //
    // What does describe them, and is therefore absent: the **device id** (it names a particular
    // pair of glasses on a particular face — it arrives fingerprinted or as a count), the
    // **Info.plist credentials** the SDK bootstrap used to dump verbatim (a client token is a
    // secret, an app id and a team id name the developer account, and a universal-link scheme is
    // the app's own callback door), the **command payload** a watch or a car sends, and the
    // **content a surface was asked to show** — a HUD card, a CarPlay row, a Live Activity's
    // state are all composed from the conversation.
    enum DeviceSurface: String {
        case glasses, watch, carPlay, liveActivity, hud, nowPlaying, sdk
    }

    enum DeviceEvent: String {
        case configured, unavailable, unsupported, configProblem
        case registrationState, registrationStarted, registrationFailed, registrationDropped
        case alreadyRegistered
        case connected, disconnected, reconnected, idle, active
        case deviceListChanged, deviceListEmpty
        case autoSleepArmed, autoSleepFired
        case sessionActivated, sessionInactive, sessionDeactivated, activationFailed
        case commandReceived, commandUnknown, commandHandled
        case started, stopped, ended, staleEnded, startFailed, notEnabled, alreadyRunning
        case renderFailed, claimed, released
        case telemetryBlocked
    }

    /// `state` is a registration or activation state — a small fixed SDK vocabulary. `command` is
    /// a *known* command name from the app's own watch/car protocol; an unrecognised one is
    /// reported as `commandUnknown` with no name, because an unknown command is text that arrived
    /// from a peer. `item` is a system-generated activity id, fingerprinted.
    @discardableResult
    static func device(_ surface: DeviceSurface, _ event: DeviceEvent,
                       state: PrivacyToken? = nil, command: PrivacyToken? = nil,
                       item: PrivateIdentifier? = nil, count: Int? = nil,
                       minutes: Int? = nil, success: Bool? = nil,
                       error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.surface, .token(PrivacyToken(surface.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let state { fields.append(.init(.state, .token(state))) }
        if let command { fields.append(.init(.command, .token(command))) }
        if let item { fields.append(.init(.item, .identifier(item))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let minutes { fields.append(.init(.minutes, .count(minutes))) }
        if let success { fields.append(.init(.success, .flag(success))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.device, .device, fields))
    }

    // MARK: - Scheduled and delivered agent work
    //
    // A scheduled task's *name* is the wearer's instruction to their agent ("check whether the
    // clinic replied"), a queued notification's body is what the agent found, and the summary the
    // queue speaks is the same content one transform later. All three are user content and none
    // has a parameter. What survives is which channel, which lifecycle event, how many items were
    // involved, how long a result was, and the model that ran — a catalog id, public.
    //
    // Persona identity is omitted rather than fingerprinted, on the batch-2 precedent: the set is
    // small and wearer-visible, so a stable hash of "the persona used most" anonymises nothing.

    enum AgentChannel: String { case scheduler, notifications, session, playbook }

    enum AgentEvent: String {
        case started, stopped, checkScheduled, onboardingRun
        case taskStarted, taskCompleted, taskFailed, taskDeferred, taskProducedNothing
        case personaSwitched, modelSwitched, modelRestored
        case queued, pruned, deliveryStarted, deliverySkipped, deliveredViaSession
        case awaitingOperator, summaryFailed, injectionDeferred
        case dispatchedWithoutFrame, replanned, yieldedToHuman
    }

    /// `priority` and `reason` are fixed app enums (`AgentNotification.Priority`, the dispatcher's
    /// no-frame reason). A model-authored reason string — the one a `yield_to_human` or a playbook
    /// `replan` carries — is model output about the wearer's task, so it arrives as `characters`.
    @discardableResult
    static func agent(_ channel: AgentChannel, _ event: AgentEvent,
                      model: PrivacyToken? = nil, priority: PrivacyToken? = nil,
                      reason: PrivacyToken? = nil, count: Int? = nil, characters: Int? = nil,
                      minutes: Int? = nil, seconds: Double? = nil,
                      error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [
            .init(.channel, .token(PrivacyToken(channel.rawValue))),
            .init(.event, .token(PrivacyToken(event.rawValue))),
        ]
        if let model { fields.append(.init(.model, .token(model))) }
        if let priority { fields.append(.init(.priority, .token(priority))) }
        if let reason { fields.append(.init(.reason, .token(reason))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let minutes { fields.append(.init(.minutes, .count(minutes))) }
        if let seconds { fields.append(.init(.elapsed, .seconds(seconds))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.agent, .agent, fields))
    }

    // MARK: - Purchases

    /// A product id is this app's own published catalog entry, so it is a token — which product
    /// failed to unlock is the entire content of a purchase bug report. Nothing else from a
    /// transaction appears: no receipt, no transaction id, no account, no price, no territory.
    enum PurchaseEvent: String {
        case catalogLoaded, catalogFailed
        case activated, cancelled, pending, resultUnknown, failed
    }

    @discardableResult
    static func purchase(_ event: PurchaseEvent, product: PrivacyToken? = nil,
                         count: Int? = nil, error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let product { fields.append(.init(.product, .token(product))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.commerce, .purchase, fields))
    }

    // MARK: - App lifecycle
    //
    // The app entry point's own chatter: process transitions, the listening master switch, turn
    // bookkeeping and the routing decisions above a turn. Most of what was here before was
    // progress narration and is simply gone; what remains is the handful of facts that make a
    // "why did it not listen / why did it pick that model / why did nothing happen" report
    // answerable.
    //
    // A turn's *text* never appears in any of it: not the transcript, not the utterance an
    // admission policy held or rejected, not a voice command's wording, not a direct tool call's
    // result, and not the answer that was spoken back.

    enum AppEvent: String {
        case loggingActive, sdkConfigured, sdkUnavailable
        case backgrounded, foregrounded, becameActive
        case backgroundOptimized, backgroundOptimizationSkipped, foregroundRestored
        case listeningEnabled, listeningDisabled, micMuted, micUnmuted
        case conversationCleared, conversationEnded
        case turnCancelled, responseCancelled, playbackStopped, alreadyProcessing
        case utteranceHeld, utteranceRejected, utteranceStaleDropped
        case bargeIn, consentAnsweredByVoice
        case voiceCommandHandled, voiceCommandDemoted, intentIgnored
        case turnClassified, directToolAnswered, directToolFellBack, turnCompleted
        case modeSwitchRedialed, modeSwitchRedialFailed
        case fieldSessionStarted, fieldSessionEnded
        case operationSettledLate, chatReadbackUnconfigured, powerPosture
        case quickDisconnect
    }

    /// `detail` and `state` are fixed app vocabularies — a routing tier, a command label, a power
    /// posture, a mode. `item` is a Field Assist vault identity, fingerprinted: a vault id names
    /// the customer whose procedures are loaded, which is the one identifier this file holds that
    /// is about someone other than the wearer.
    @discardableResult
    static func app(_ event: AppEvent, detail: PrivacyToken? = nil, state: PrivacyToken? = nil,
                    tool: PrivacyToken? = nil, model: PrivacyToken? = nil,
                    item: PrivateIdentifier? = nil, count: Int? = nil, characters: Int? = nil,
                    success: Bool? = nil, error: SafeErrorSummary? = nil) -> PrivacyEvent {
        var fields: [PrivacyEvent.Field] = [.init(.event, .token(PrivacyToken(event.rawValue)))]
        if let detail { fields.append(.init(.detail, .token(detail))) }
        if let state { fields.append(.init(.state, .token(state))) }
        if let tool { fields.append(.init(.tool, .token(tool))) }
        if let model { fields.append(.init(.model, .token(model))) }
        if let item { fields.append(.init(.item, .identifier(item))) }
        if let count { fields.append(.init(.count, .count(count))) }
        if let characters { fields.append(.init(.characters, .count(characters))) }
        if let success { fields.append(.init(.success, .flag(success))) }
        if let error { fields.append(.init(.error, .summary(error))) }
        return emit(.init(.lifecycle, .app, fields))
    }

    // MARK: - Network

    enum NetworkSubsystem: String { case homeAssistant, contextFetch, modelCatalog }

    @discardableResult
    static func requestFailed(_ subsystem: NetworkSubsystem, _ summary: SafeErrorSummary) -> PrivacyEvent {
        return emit(.init(.network, .requestFailed, [
            .init(.subsystem, .token(PrivacyToken(subsystem.rawValue))),
            .init(.error, .summary(summary)),
        ]))
    }
}

// MARK: - Bounded value types

/// A short word from a bounded vocabulary — an event type, a tool name, a state, an error case.
///
/// Anything outside `[A-Za-z0-9._-]`, empty, or longer than 48 characters is **dropped** rather
/// than truncated, and becomes `unnamed`. Dropping is the point: a transcript, a URL with a query,
/// a JSON argument blob, or a sentence-shaped error message all contain characters outside the
/// set, so they cannot arrive here in a shortened form either.
///
/// **Stated limit:** this is a shape filter, not a secret detector. A value that happens to be
/// short and identifier-shaped survives it. No call site may construct a token from a credential,
/// and `Scripts/check-privacy-logging.sh` flags log calls that interpolate identifiers named like
/// `token`/`key`/`cookie` precisely because the type cannot tell.
struct PrivacyToken: Equatable, CustomStringConvertible {
    static let placeholder = "unnamed"
    static let maxLength = 48

    let description: String

    init(_ raw: String) {
        let allowed = !raw.isEmpty
            && raw.count <= Self.maxLength
            && raw.allSatisfy { char in
                char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "." || char == "-")
            }
        description = allowed ? raw : Self.placeholder
    }

    /// The case name of an enum value, with any associated payload left behind.
    ///
    /// `Mirror` gives the case label for a payload case (`disallowedScheme`) without the payload.
    /// A payload-free case has no children, and there `String(describing:)` is the case name —
    /// **but only if the type has not customised it**. `URLFetchGuard.Rejection` is exactly that
    /// trap: it is `CustomStringConvertible`, and its description names the host it refused. So a
    /// customised type yields `nil` here and the caller falls back to the type name; a guess would
    /// be the leak this whole file exists to prevent. Anything that is not an enum yields `nil`
    /// too, and every result still passes through the vocabulary filter above.
    static func caseName(of value: Any) -> PrivacyToken? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .enum else { return nil }
        if let label = mirror.children.first?.label { return PrivacyToken(label) }
        guard mirror.children.isEmpty else { return nil }
        guard !(value is CustomStringConvertible), !(value is CustomDebugStringConvertible) else {
            return nil
        }
        return PrivacyToken(String(describing: value))
    }
}

/// A value that may appear in a log only as a one-way fingerprint: a call id, an item id, a host.
///
/// Short enough to read, long enough to correlate two records within a session, and not reversible
/// into the value. Wrapping is explicit at the call site so "this is an identifier" is a decision
/// someone made, not something a formatter guessed.
struct PrivateIdentifier: Equatable, CustomStringConvertible {
    let description: String

    init(_ raw: String) {
        description = SHA256.hash(data: Data(raw.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Event shape

/// One structured record. Pure data — building one has no side effect, which is what lets the
/// encoder be tested without a log sink.
struct PrivacyEvent: Equatable {

    /// The closed set of events this app emits. A new event is a new case, reviewable as a diff.
    enum Name: String, CaseIterable {
        case toolCallReceived, toolCallRefused, toolCallAcked, toolCallCancelled, toolCallCompleted
        case realtimeSession, realtimeUtterance, realtimeMedia, realtimeSendSkipped
        case realtimeTruncated, realtimeReconnectScheduled, realtimeReconnectExhausted
        case realtimeGoAway, realtimeToolCall, realtimeToolCancellation, realtimeLatency
        case realtimeError
        case qrScanned, qrFetchBlocked, qrFetchLoaded
        case homeOperation, homeEntityResolved, homeFallback
        case deepLink
        case authFailed, keychainFailed, configMigration
        case requestFailed
        case gatewayConnection, gatewayHealth, gatewayOperation, gatewayNotification, gatewayFailed
        case mcpDiscovery, mcpToolScreened, mcpEgress, mcpFailed, mcpServer
        case stream
        case toolGate, toolDispatch, toolRun, toolAuthorizationRefused, webSearch
        case wakeWord, speech, tts
        case audio
        case model, modelCompaction, localModel
        case conversation
        case camera, photoLibrary, vision, face
        case homeBridge, medical, location, proactiveAlert
        case store, transfer
        case recording, device, agent, purchase, app
    }

    /// Field keys are closed too, so a reader can rely on the shape of a category's lines.
    enum Key: String {
        case tool, invocation, outcome, duration
        case provider, event, detail, direction, characters, kind, kilobytes, sequence
        case reason, state, item, attempt, ofAttempts, delay, remaining, count, phase
        case payload, bytes, host
        case operation, success, match
        case route, source, verdict, action
        case subsystem, error
        case status, migration
        case transport, peer, method
        case server, servers, port
        case channel, session
        case distance, language, engine, voice, quality, elapsed
        case device, owner, hertz, channels
        case model, configuration, tokens, megabytes, total, vision, shape
        case cacheMegabytes, footprintMegabytes, headroomMegabytes
        case messagesBefore, messagesAfter, tokensBefore, tokensAfter, signals
        case store, thread, minutes
        case resolution, frameRate, width, height
        case posture, percent, extraction, confidence, days
        case slot, scope, version, signed
        case surface, command, product, priority, bitrate, measuredBitrate
    }

    /// The only shapes a field value can take. There is no `case text(String)` — that absence is
    /// the whole design.
    enum Value: Equatable {
        case count(Int)
        case milliseconds(Int)
        case seconds(Double)
        case flag(Bool)
        case token(PrivacyToken)
        case identifier(PrivateIdentifier)
        case summary(SafeErrorSummary)
    }

    struct Field: Equatable {
        let key: Key
        let value: Value

        init(_ key: Key, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    let category: PrivacyLog.Category
    let name: Name
    let fields: [Field]

    init(_ category: PrivacyLog.Category, _ name: Name, _ fields: [Field]) {
        self.category = category
        self.name = name
        self.fields = fields
    }
}

// MARK: - Encoder

/// Turns an event into the exact line the `os.Logger` sink emits. Pure, so the privacy property
/// — that no supplied content reaches the output — is a unit test rather than a promise.
enum PrivacyEventEncoder {
    static func encode(_ event: PrivacyEvent) -> String {
        var line = "[\(event.category.rawValue)] \(event.name.rawValue)"
        for field in event.fields {
            line += " \(field.key.rawValue)=\(render(field.value))"
        }
        return line
    }

    static func render(_ value: PrivacyEvent.Value) -> String {
        switch value {
        case .count(let n): return String(n)
        case .milliseconds(let ms): return "\(ms)ms"
        case .seconds(let s): return String(format: "%.1fs", s)
        case .flag(let flag): return flag ? "true" : "false"
        case .token(let token): return token.description
        case .identifier(let identifier): return "#\(identifier.description)"
        case .summary(let summary): return summary.description
        }
    }
}
