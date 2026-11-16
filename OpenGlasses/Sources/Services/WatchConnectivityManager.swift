import Combine
import CoreLocation
import Foundation
import UIKit
import WatchConnectivity

/// iPhone-side WatchConnectivity manager. Receives commands from the Watch app
/// and dispatches them to AppState for execution.
@MainActor
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    weak var appState: AppState?

    private var session: WCSession?

    /// Plan LT §3: one watch photo request at a time; a second gets `.busy` at once.
    private var photoGate = WatchPhotoGate()

    /// Whether a watch with Avenkin installed is paired — the Apple Watch settings row shows only
    /// then.
    @Published private(set) var isWatchAppInstalled = false

    /// Map cards on the wrist (Plan GM). Every application-context push goes through it, so the
    /// status and the surfaces always travel together.
    private(set) var surfacePublisher: WatchSurfacePublisher?

    /// Today's calendar and weather on the wrist (Plan KS), folded into every push by the surface
    /// publisher.
    private(set) var todayPublisher: WatchTodayPublisher?

    /// The state the wrist shows, watched so the watch hears about a change it did not cause.
    private var stateObservers: Set<AnyCancellable> = []
    /// The evening check-in's list, watched for the wrist's line (Plan LE §8).
    private var checkInObserver: AnyCancellable?

    /// The watch protocol's fixed command vocabulary.
    ///
    /// A command arrives as a dictionary value from the paired device, so it is *classified*
    /// against this set rather than quoted — an unrecognised string is peer-supplied text, and
    /// the same rule the local MCP server applies to an unknown request path applies here. The
    /// message's other fields (an `ask` command carries the wearer's question, a `quickAction`
    /// its label) are never logged at all.
    nonisolated static func commandToken(_ raw: String) -> PrivacyToken? {
        let known: Set<String> = [
            "toggleListen", "toggleRecord", "toggleVideo", "capturePhoto", "photo", "describe",
            "ask", "persona", "connect", "disconnect", "sleep", "status",
            "quickAction", "resumeThread", WatchDictation.command, WatchStartGuidance.command,
            WatchPreparedCardWire.command, WatchPrivateWire.command, WatchGridWire.command,
        ]
        return known.contains(raw) ? PrivacyToken(raw) : nil
    }

    override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            PrivacyLog.device(.watch, .unsupported)
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        let today = WatchTodayPublisher(
            environment: .init(
                watchAppInstalled: { session.isPaired && session.isWatchAppInstalled },
                sourceAccessReady: { [weak self] in self?.appState?.myDaySourceAccessReady ?? false },
                cards: { [weak self] in self?.appState?.myDayService.todayFeed.cards ?? [] },
                // Plan LE §8: the evening check-in's line.
                waiting: { [weak self] now, redacted in self?.appState?.checkInWatchLine(now: now, redacted: redacted) }),
            refresh: { [weak self] in _ = await self?.appState?.myDayService.refresh(channel: nil) },
            onChange: { [weak self] in self?.sendStatusUpdate() })
        todayPublisher = today
        let publisher = WatchSurfacePublisher(
            session: session,
            todayValue: { [weak today] in today?.contextValue() },
            baseContext: { [weak self] in self?.statusContext() })
        if let bus = appState?.glanceSurfaces { publisher.observe(bus) }
        surfacePublisher = publisher
        if let myDay = appState?.myDayService { today.start(observing: myDay) }
        // Plan LE §8: a new read of the check-in's list may change the wrist's line.
        checkInObserver = appState?.eveningCheckIn.$latest
            .receive(on: DispatchQueue.main)
            .sink { [weak today] _ in today?.valueMayHaveChanged() }
        PrivacyLog.device(.watch, .sessionActivated)
        observeState()
    }

    /// Tell the watch when listening or the glasses link changes, whoever changed it.
    ///
    /// Without this the watch only heard back after a command of its own, so a turn that ended on
    /// the phone left the wrist — and the Listen complication — saying "Listening" indefinitely.
    /// `@Published` emits in `willSet`, and `sendStatusUpdate()` reads `appState` rather than the
    /// value handed over, so delivery waits for the next main-queue turn, where the property is set.
    private func observeState() {
        guard let appState else { return }
        stateObservers.removeAll()
        // Plan LU P1b: and when a private conversation starts or ends, so the wrist's badge and
        // its idle summary follow the phone however it was started or ended.
        Publishers.Merge3(appState.$isListening.removeDuplicates().dropFirst(),
                          appState.$isConnected.removeDuplicates().dropFirst(),
                          appState.privateConversation.$state.map(\.isActive).removeDuplicates().dropFirst())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendStatusUpdate() }
            .store(in: &stateObservers)
        // The wrist's tiles follow the phone's grid: an arrangement edited, a speed-dial action
        // added, or a model that can or cannot see. Defaults change often, so only a change in the
        // tiles themselves sends anything.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .compactMap { [weak self] _ in
                // Delivered on the main queue by the line above.
                MainActor.assumeIsolated {
                    self?.appState.map { WatchGridWire.encode(WatchConnectivityManager.gridTiles(for: $0)) }
                }
            }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendStatusUpdate() }
            .store(in: &stateObservers)
    }

    /// The phone grid's first tiles, as the dock draws them now.
    private static func gridTiles(for appState: AppState) -> [WatchGridWire.Tile] {
        let defaults = UserDefaults.standard
        let slots = DockGridCatalog.storedSlots(
            dockOrder: defaults.string(forKey: "dockItemOrder") ?? "",
            storedArrangement: defaults.string(forKey: "homeGridArrangement") ?? "",
            quickActions: Config.quickActions,
            showsActions: true,
            restricted: AdminGate.shared.isRestricted)
        return WatchGridTiles.tiles(slots: slots, photoBlocked: photoBlocked(appState))
    }

    /// The dock's rule for dimming its photo tiles.
    private static func photoBlocked(_ appState: AppState) -> Bool {
        appState.currentMode.isRealtime
            ? !appState.realtimeSupportsVision
            : HomeGridPhotoPolicy.blocksPhoto(activeModel: Config.activeModel)
    }

    /// A tile tapped on the wrist, run as the phone's tile runs, never opening the phone's camera.
    private func runGridTile(_ message: [String: Any], appState: AppState) async -> [String: Any] {
        let route = WatchGridTiles.route(entryId: message[WatchGridWire.entryIdKey] as? String,
                                         quickActions: Config.quickActions,
                                         photoBlocked: Self.photoBlocked(appState),
                                         glassesConnected: appState.isConnected)
        let busy: [String: Any] = ["error": String(localized: "Avenkin is still working on something.")]
        switch route {
        case .refused(let reason):
            return ["error": reason]
        case .photo:
            return await self.watchPhotoTurn(appState) {
                await appState.captureAndAnalyzePhoto(phoneCameraFallback: false)
            }
        case .photoTurn(let prompt):
            return await self.watchPhotoTurn(appState) {
                await appState.capturePhotoAndSend(prompt: prompt, phoneCameraFallback: false)
            }
        case .textTurn(let prompt):
            // Checked first, as for a dictated question: a turn in flight would swallow this one
            // and the reply would carry the previous answer.
            guard !appState.isProcessing else { return busy }
            await appState.sendTextMessage(prompt, speakResponse: WatchDictation.speaksAnswerNow())
            return ["status": "completed", "response": appState.lastResponse]
        case .quickAction(let action):
            guard !appState.isProcessing else { return busy }
            let answered = action.type == .prompt || action.type == .homeAssistant
            let before = appState.lastResponse
            let errorBefore = appState.errorMessage
            let wasRecording = appState.sessionRecorder.isRecording
            await appState.executeQuickAction(action)
            if action.type == .toggleRecording, !wasRecording, !appState.sessionRecorder.isRecording {
                return ["error": String(localized: "Recording didn't start."), "status": statusString()]
            }
            // Only a turn that answered sends an answer: a light, a shortcut or a recording leaves
            // `lastResponse` as an earlier turn's, and the wrist must not show that as this one's.
            if answered, appState.lastResponse != before {
                return ["status": "completed", "response": appState.lastResponse]
            }
            if answered, let error = appState.errorMessage, !error.isEmpty, error != errorBefore {
                return ["error": error]
            }
            return ["status": statusString()]
        }
    }

    /// Send current app status to the Watch for display.
    ///
    /// Not gated on reachability: the watch is reachable only while its app is on screen, and the
    /// application context is exactly the channel that reaches it when it is not — the system
    /// keeps the latest one and hands it over when the watch app next runs. A phone with no watch,
    /// or a watch without the app, is skipped before anything is gathered. The surface publisher
    /// sends it, with any live map card folded in (Plan GM).
    func sendStatusUpdate() {
        surfacePublisher?.push()
    }

    /// Plan LA P3: a Direct turn ended with the done tone. The wrist taps once (`.success`) — only
    /// while the watch app is reachable, because a tap delivered later would confirm nothing. The
    /// message carries no words, only the event.
    func sendQuietDone() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(QuietDoneWatchMessage.payload, replyHandler: nil, errorHandler: nil)
    }

    /// The idle summary's reply line: the last 200 characters' worth of the reply, or the fixed
    /// line in its place while a private conversation is open (Plan LU §3). A reply to a request
    /// made on the watch is not this: it goes back to the watch whole (`watchRequestReply`). Pure.
    nonisolated static func lastResponsePayload(_ lastResponse: String, placeholder: String?) -> String {
        if let placeholder { return placeholder }
        return String(lastResponse.prefix(200))
    }

    /// The recent conversations the watch lists: the last five, title and one line each. The line
    /// is the conversation's note headline when it has one, else the word-prefix summary (Plan LQ
    /// §6). Never a message body.
    nonisolated static func recentThreadsPayload(_ threads: [ConversationThread]) -> [[String: String]] {
        threads.prefix(5).map { thread in
            [
                "id": thread.id,
                "title": thread.title,
                "summary": thread.listSummary ?? "",
                "updatedAt": ISO8601DateFormatter().string(from: thread.updatedAt)
            ]
        }
    }

    /// The phone's status as the watch reads it: flat keys, plus `job` while a job is open. The
    /// surface publisher adds `surfaces` and `today`.
    private func statusContext() -> [String: Any]? {
        guard let appState else { return nil }

        // Recent conversation threads (last 5, title + summary only)
        let recentThreads = Self.recentThreadsPayload(appState.conversationStore.threads)

        // Top 4 quick actions
        let quickActions: [[String: String]] = Config.quickActions.prefix(4).map { action in
            [
                "id": action.id,
                "label": action.label,
                "icon": action.icon,
                "type": action.type.rawValue
            ]
        }

        var context: [String: Any] = [
            "status": statusString(),
            "isConnected": appState.isConnected,
            "isProcessing": appState.isProcessing,
            "isListening": appState.isListening,
            "isRecording": appState.transcriptionService.isRecording,
            "isVideoRecording": appState.videoRecorder.isRecording,
            "lastResponse": Self.lastResponsePayload(
                appState.lastResponse, placeholder: PrivateConversationGate.placeholder(for: .watchLastResponse)),
            // Plan LU §7: the watch shows the Private badge while one is open.
            WatchPrivateWire.contextKey: PrivateConversationGate.isActive,
            "deviceName": appState.glassesService.deviceName ?? "",
            "batteryLevel": appState.glassesService.batteryLevel ?? 0,
            "personas": Config.enabledPersonas.prefix(3).map { ["id": $0.id, "name": $0.name] },
            "accentColor": Config.accentColorName,
            "recentThreads": recentThreads,
            "quickActions": quickActions,
            WatchGridWire.contextKey: WatchGridWire.encode(Self.gridTiles(for: appState))
        ]

        // Plan FO P3a — read-only job state on the wrist: which job, running or paused, which
        // machine, and what the app is waiting on. The key is absent when no job is open, so a
        // watch that has not been updated, and a watch whose technician has finished, both show
        // nothing rather than something stale.
        if let job = JobWatchPayload.payload(for: FieldSessionService.shared.activeSession) {
            context[JobWatchPayload.key] = job.dictionary
        }
        return context
    }

    /// Run one photo turn for the watch and word its reply (Plan LT §3). A second request while
    /// one runs, or while the app is busy with another turn, is answered busy at once.
    private func watchPhotoTurn(_ appState: AppState,
                                _ turn: () async -> PhotoTurnResult) async -> [String: Any] {
        guard photoGate.begin(appBusy: appState.isProcessing) else {
            return WatchPhotoReply.dictionary(for: .busy)
        }
        defer { photoGate.end() }
        return WatchPhotoReply.dictionary(for: await turn())
    }

    /// Plan GM P1a — **Go** on a wrist map card.
    private func startGuidance(_ message: [String: Any], appState: AppState) async -> [String: Any] {
        let resolution = WatchStartGuidance.resolve(
            surfaceId: message[WatchStartGuidance.surfaceIdKey] as? String,
            placeId: message[WatchStartGuidance.placeIdKey] as? String,
            live: appState.glanceSurfaces.current)
        switch resolution {
        case .refuse(let reason):
            return WatchStartGuidance.dictionary(.refused(reason))
        case .start(let target):
            let coordinate = CLLocationCoordinate2D(latitude: target.coordinate.latitude,
                                                    longitude: target.coordinate.longitude)
            let appIsActive = UIApplication.shared.applicationState == .active
            do {
                let spoken = try await appState.walkingRoute.start(to: coordinate, label: target.label)
                return WatchStartGuidance.dictionary(
                    WatchStartGuidance.reply(spoken: spoken, error: nil, appIsActive: appIsActive))
            } catch {
                return WatchStartGuidance.dictionary(
                    WatchStartGuidance.reply(spoken: nil, error: error, appIsActive: appIsActive))
            }
        }
    }

    private func refreshWatchAppInstalled(_ session: WCSession) {
        isWatchAppInstalled = session.isPaired && session.isWatchAppInstalled
    }

    private func statusString() -> String {
        guard let appState else { return "idle" }
        if appState.isListening { return "listening" }
        if appState.isProcessing { return "processing" }
        if appState.speechService.isSpeaking { return "speaking" }
        return "idle"
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        PrivacyLog.device(.watch, error == nil ? .sessionActivated : .activationFailed,
                          state: PrivacyToken(String(activationState.rawValue)),
                          error: error.map(SafeErrorSummary.init))
        Task { @MainActor in self.refreshWatchAppInstalled(session) }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshWatchAppInstalled(session)
            // A watch app installed since the last push has not seen the status or a card yet.
            self.sendStatusUpdate()
            self.todayPublisher?.refreshIfDue()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        PrivacyLog.device(.watch, .sessionInactive)
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        PrivacyLog.device(.watch, .sessionDeactivated)
        session.activate()
    }

    /// Handle transferUserInfo payloads from Watch complications (no reply handler).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let command = userInfo["command"] as? String else { return }
        PrivacyLog.device(.watch, .commandReceived, command: Self.commandToken(command))

        // Synthesize a fake message and dispatch through the same Task path.
        // Complications use transferUserInfo so there is no reply handler — use a no-op.
        Task { @MainActor in
            guard let appState = self.appState else { return }

            switch command {
            case "toggleListen":
                if appState.isListening {
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.stopRecording()
                    appState.isListening = false
                } else {
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                }

            case "toggleRecord":
                if appState.transcriptionService.isRecording {
                    await appState.transcriptionService.stopRecordingAfterTail()
                } else {
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.startRecording()
                }

            case "capturePhoto":
                // Silent capture — no LLM, no TTS, transcription keeps running.
                // Photo is saved to Documents/Photos/ and a timestamped note is
                // injected into the caption stream.
                await appState.capturePhotoSilently()

            case "toggleVideo":
                await appState.toggleRecording()

            default:
                PrivacyLog.device(.watch, .commandUnknown)
            }

            self.sendStatusUpdate()
        }
    }

    /// Handle real-time messages from the Watch with reply handler.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = message["command"] as? String else {
            replyHandler(["error": String(localized: "No command specified")])
            return
        }

        PrivacyLog.device(.watch, .commandReceived, command: Self.commandToken(command))

        Task { @MainActor in
            guard let appState = self.appState else {
                replyHandler(["error": String(localized: "App not ready")])
                return
            }

            switch command {
            case "ask":
                // Trigger wake word flow — start listening
                appState.wakeWordService.stopListening()
                try? await Task.sleep(nanoseconds: 100_000_000)
                await appState.handleWakeWordDetected()
                replyHandler(["status": "listening"])

            case WatchDictation.command:
                // A question dictated on the watch: a typed turn, answered on the wrist and — when
                // the wearer has something on to hear it — in their ear. Checked for a turn already
                // in flight first: `sendTextMessage` would do nothing, and the reply would carry
                // the previous answer as if it were this one.
                if let question = WatchDictation.question(from: message) {
                    if appState.isProcessing {
                        replyHandler(["error": String(localized: "Avenkin is still working on something.")])
                    } else {
                        await appState.sendTextMessage(question,
                                                       speakResponse: WatchDictation.speaksAnswerNow())
                        replyHandler([
                            "status": "completed",
                            "response": appState.lastResponse
                        ])
                    }
                } else {
                    replyHandler(["error": String(localized: "I didn't catch a question.")])
                }

            case "persona":
                // Activate a specific persona agent and start listening
                if let personaId = message["persona_id"] as? String,
                   let persona = Config.enabledPersonas.first(where: { $0.id == personaId }) {
                    appState.activePersona = persona
                    Config.setActiveModelId(persona.modelId)
                    Config.setActivePresetId(persona.presetId)
                    appState.llmService.refreshActiveModel()
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                    replyHandler(["status": "listening", "persona": persona.name])
                } else {
                    replyHandler(["error": String(localized: "Persona not found")])
                }

            // Plan LT §3: a photo command replies with its own result — the answer it made, or
            // an error line — never `lastResponse`, and opens no phone camera from the wrist.
            case "photo":
                replyHandler(await self.watchPhotoTurn(appState) {
                    await appState.captureAndAnalyzePhoto(phoneCameraFallback: false)
                })

            case "describe":
                replyHandler(await self.watchPhotoTurn(appState) {
                    await appState.capturePhotoAndSend(prompt: "Describe what you see in detail.",
                                                       phoneCameraFallback: false)
                })

            case "capturePhoto":
                // Silent glasses photo — no LLM, no TTS. Saved to Documents/Photos/ with a
                // timestamped caption note. Transcription/listening keep running.
                await appState.capturePhotoSilently()
                replyHandler(["status": "captured"])

            case "toggleVideo":
                // Start/stop glasses video recording. Reflect the new state back to the Watch.
                await appState.toggleRecording()
                replyHandler([
                    "status": appState.videoRecorder.isRecording ? "recording" : "stopped",
                    "isVideoRecording": appState.videoRecorder.isRecording
                ])

            case "connect":
                await appState.connectAndListen()
                replyHandler([
                    "status": "connecting",
                    "isConnected": appState.isConnected
                ])

            case "toggleListen":
                if appState.isListening {
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.stopRecording()
                    appState.isListening = false
                    replyHandler(["status": "stopped", "isListening": false])
                } else {
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                    replyHandler(["status": "listening", "isListening": true])
                }

            case "toggleRecord":
                let isRecording = appState.transcriptionService.isRecording
                if isRecording {
                    // Stop transcription-only recording, hearing out the last word
                    await appState.transcriptionService.stopRecordingAfterTail()
                    PrivacyLog.device(.watch, .commandHandled,
                                      command: PrivacyToken("toggleRecord"), success: false)
                    replyHandler([
                        "status": "stopped",
                        "isRecording": false
                    ])
                } else {
                    // Start transcription-only recording (no LLM, no wake word)
                    appState.wakeWordService.stopListening()
                    appState.transcriptionService.startRecording()
                    PrivacyLog.device(.watch, .commandHandled,
                                      command: PrivacyToken("toggleRecord"), success: true)
                    replyHandler([
                        "status": "recording",
                        "isRecording": true
                    ])
                }

            case "quickAction":
                if let actionId = message["action_id"] as? String,
                   let action = Config.quickActions.first(where: { $0.id == actionId }) {
                    switch action.type {
                    case .photo, .photoThenPrompt:
                        replyHandler(await self.watchPhotoTurn(appState) {
                            await appState.captureAndAnalyzePhoto(phoneCameraFallback: false)
                        })
                    case .toggleRecording:
                        let wasRecording = appState.sessionRecorder.isRecording
                        await appState.executeQuickAction(action)
                        // Nothing was answered, so no answer is sent: `lastResponse` is an
                        // earlier turn's. A start that did not take says so, rather than the
                        // watch tapping success for a recording that is not running.
                        if !wasRecording && !appState.sessionRecorder.isRecording {
                            replyHandler(["error": String(localized: "Recording didn't start."),
                                          "status": self.statusString()])
                        } else {
                            replyHandler(["status": self.statusString()])
                        }
                    case .prompt:
                        replyHandler(await self.watchPhotoTurn(appState) {
                            await appState.capturePhotoAndSend(prompt: action.label,
                                                               phoneCameraFallback: false)
                        })
                    default:
                        replyHandler(await self.watchPhotoTurn(appState) {
                            await appState.capturePhotoAndSend(prompt: action.label,
                                                               phoneCameraFallback: false)
                        })
                    }
                } else {
                    replyHandler(["error": String(localized: "Quick action not found")])
                }

            case WatchGridWire.command:
                replyHandler(await self.runGridTile(message, appState: appState))

            case "resumeThread":
                if let threadId = message["thread_id"] as? String {
                    // Plan FO P1: the two-step resume through the one seam — this used to set the
                    // id alone, so the watch resumed a conversation the model had no history of.
                    // A job keeps its own conversation: the watch has nowhere to put the
                    // "keep this in the job?" question, so it does not take the technician out of one.
                    if appState.guidedJobFlow.leaveJobThreadQuestion(switchingTo: threadId) == nil {
                        appState.activateConversationThread(threadId)
                    }
                    // Start listening for follow-up in the resumed thread
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected()
                    replyHandler(["status": "resumed", "thread_id": threadId])
                } else {
                    replyHandler(["error": String(localized: "No thread ID")])
                }

            case WatchStartGuidance.command:
                replyHandler(await self.startGuidance(message, appState: appState))

            // Plan LU P1b: the wrist's Private button and its End.
            case WatchPrivateWire.command:
                if let action = WatchPrivateWire.action(from: message) {
                    replyHandler(appState.handleWatchPrivateRequest(action))
                } else {
                    replyHandler(["error": "Unknown private conversation request"])
                }

            case WatchPreparedCardWire.command:
                // Plan KT §6.7: a press on a wrist card. `stage` is the Display's Send on phone.
                let reply = await appState.watchPreparedCardHandler.handle(message)
                replyHandler(WatchPreparedCardCommand.dictionary(reply))

            case "disconnect", "sleep":
                appState.disconnectGlasses()
                replyHandler(["status": "disconnected"])

            case "status":
                replyHandler([
                    "status": self.statusString(),
                    "isConnected": appState.isConnected,
                    "lastResponse": Self.lastResponsePayload(
                        appState.lastResponse,
                        placeholder: PrivateConversationGate.placeholder(for: .watchLastResponse))
                ])

            default:
                // Treat as a custom prompt
                if let prompt = message["prompt"] as? String {
                    replyHandler(await self.watchPhotoTurn(appState) {
                        await appState.capturePhotoAndSend(prompt: prompt, phoneCameraFallback: false)
                    })
                } else {
                    replyHandler(["error": String(localized: "Unknown command: \(command)")])
                }
            }

            self.sendStatusUpdate()
        }
    }
}
