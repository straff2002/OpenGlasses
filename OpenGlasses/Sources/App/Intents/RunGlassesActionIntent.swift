import AppIntents
import Foundation

/// The one generic Siri intent behind the user-curated action catalog (Plan BQ P1).
/// "Run *daily briefing* on OpenGlasses" — the `action` entity resolves against whatever
/// the user has exposed in Settings → Siri & Search.
struct RunGlassesActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Run OpenGlasses Action"
    // App Intent metadata must not name a reserved term — App Store Connect rejects the upload
    // with ITMS-90626 ("Invalid Siri Support") if a title or description contains "Siri" (or
    // "Apple"). Ordinary UI copy is unaffected; only extracted intent metadata is scanned.
    static var description = IntentDescription(
        "Run an OpenGlasses action you've exposed for voice — built-in, authored, or custom"
    )

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Action")
    var action: SiriActionEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let appState = try await IntentSupport.awaitConnectedAppState()
        let catalog = SiriActionCatalogProvider.current()

        guard let entry = catalog.entry(id: action.id) else {
            throw SiriActionError.notFound
        }
        guard entry.isEnabled else {
            throw SiriActionError.disabled
        }

        let result = try await SiriActionDispatcher.run(entry.binding, appState: appState)
        let snippet = AnswerSnippetView(personaName: nil, answer: result)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result), view: snippet)
    }
}

enum SiriActionError: Error, CustomLocalizedStringResourceConvertible {
    case notFound
    case disabled
    case busy
    case noResponse

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound:
            return "That action no longer exists. Check OpenGlasses Settings → Siri & Search."
        case .disabled:
            return "That action is turned off in OpenGlasses Settings → Siri & Search."
        case .busy:
            return "OpenGlasses is busy with another request. Try again in a moment."
        case .noResponse:
            return "OpenGlasses didn't return a response. Try again."
        }
    }
}

/// Maps a `SiriActionBinding` to the app machinery that fulfils it. Tool failures come back
/// as speakable text (not thrown) so Siri reads something useful instead of a generic error.
@MainActor
enum SiriActionDispatcher {

    /// Why this binding can't run, or nil to proceed.
    ///
    /// The catalog drops such a binding at admission, but an action saved by an earlier build is
    /// already in `SiriExposureConfig` — so the dispatcher re-decides rather than trusting that
    /// what reached it was screened. Pure, so the refusal is asserted without an `AppState`.
    static func refusalReason(for binding: SiriActionBinding) -> String? {
        guard let tool = binding.toolName, ComposedToolPolicy.isRestrictedTarget(tool) else {
            return nil
        }
        return ComposedToolPolicy.refusalMessage(target: tool)
    }

    static func run(_ binding: SiriActionBinding, appState: AppState) async throws -> String {
        if let refusal = refusalReason(for: binding) { return refusal }
        switch binding {
        case .builtin(let id):
            return try await BuiltinActionRunner.run(id, appState: appState)

        case .prompt(let text):
            guard !appState.isProcessing else { throw SiriActionError.busy }
            await appState.sendTextMessage(text, speakResponse: false)
            let answer = appState.lastResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw SiriActionError.noResponse }
            return answer

        case .tool(let name, let argsJSON):
            return await IntentSupport.runTool(name, args: Self.parseArgs(argsJSON), appState: appState)

        case .capability(let kind, let id):
            switch kind {
            case .captureFlow:
                return await IntentSupport.runTool(
                    "capture_flow", args: ["action": "start", "flow_id": id], appState: appState)
            case .procedure:
                return await IntentSupport.runTool(
                    "procedure_runner", args: ["action": "start", "procedure_id": id], appState: appState)
            case .playbook:
                return await IntentSupport.runTool(
                    "playbook", args: ["action": "start", "playbook_id": id], appState: appState)
            case .customTool:
                return await IntentSupport.runTool(id, args: [:], appState: appState)
            }
        }
    }

    static func parseArgs(_ json: String) -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

/// Fulfils the curated built-in actions — the same `AppState` calls the static intents make,
/// returned as a uniform speakable string.
@MainActor
enum BuiltinActionRunner {
    static func run(_ id: String, appState: AppState) async throws -> String {
        switch id {
        case "take_photo":
            await appState.captureAndAnalyzePhoto()
            return nonEmpty(appState.lastResponse, fallback: "Photo captured.")

        case "capture_photo":
            guard appState.isConnected else { return "Connect your glasses first." }
            await appState.capturePhotoSilently()
            return "Photo saved."

        case "record_video":
            guard appState.isConnected else { return "Connect your glasses first." }
            await appState.toggleRecording()
            return appState.videoRecorder.isRecording ? "Recording started." : "Recording stopped."

        case "describe_scene": return await vision(.describe, appState)
        case "read_text": return await vision(.read, appState)
        case "translate_text": return await vision(.translate, appState)
        case "analyze_food": return await vision(.health, appState)
        case "identify_object": return await vision(.identify, appState)
        case "describe_environment": return await vision(.accessibility, appState)

        case "connect_glasses":
            await appState.connectAndListen()
            return appState.isConnected ? "Connected and listening." : "Could not connect to glasses."

        case "disconnect_glasses":
            guard appState.isConnected else { return "Glasses are already disconnected." }
            appState.disconnectGlasses()
            return "Glasses disconnected."

        case "toggle_glasses":
            if appState.isConnected {
                appState.disconnectGlasses()
                return "Glasses disconnected."
            }
            await appState.connectAndListen()
            return appState.isConnected ? "Connected and listening." : "Could not connect."

        case "listening_on":
            UserDefaults.standard.set(true, forKey: "listeningEnabled")
            appState.setListeningEnabled(true)
            return "Listening enabled."

        case "listening_off":
            UserDefaults.standard.set(false, forKey: "listeningEnabled")
            appState.setListeningEnabled(false)
            return "Listening disabled."

        case "gemini_live_toggle":
            if appState.currentMode != .geminiLive {
                appState.switchMode(to: .geminiLive)
                try await Task.sleep(nanoseconds: 600_000_000)
            }
            if appState.geminiLiveSession.isActive {
                appState.geminiLiveSession.stopSession()
                return "Live session stopped."
            }
            await appState.geminiLiveSession.startSession()
            return "Live session started."

        case let modeId where modeId.hasPrefix("live_mode_"):
            return try await startLiveMode(String(modeId.dropFirst("live_mode_".count)), appState)

        case "memory_rewind":
            return await IntentSupport.runTool("memory_rewind", args: ["action": "rewind"], appState: appState)
        case "daily_briefing":
            return await IntentSupport.runTool("daily_briefing", args: [:], appState: appState)
        case "teleprompter_start":
            return await IntentSupport.runTool("teleprompter", args: ["action": "start"], appState: appState)
        case "teleprompter_stop":
            return await IntentSupport.runTool("teleprompter", args: ["action": "stop"], appState: appState)
        case "meeting_summary":
            return await IntentSupport.runTool("meeting_summary", args: [:], appState: appState)
        case "save_location":
            return await IntentSupport.runTool("save_location", args: [:], appState: appState)

        case "broadcast_toggle":
            await appState.toggleBroadcast()
            return appState.broadcastService.isBroadcasting ? "Broadcasting started." : "Broadcasting stopped."

        default:
            throw SiriActionError.notFound
        }
    }

    private static func vision(_ mode: QuickVisionMode, _ appState: AppState) async -> String {
        await appState.capturePhotoAndSend(prompt: mode.prompt)
        return nonEmpty(appState.lastResponse, fallback: "Done.")
    }

    private static func startLiveMode(_ mode: String, _ appState: AppState) async throws -> String {
        Config.setActiveLiveAIModeId(mode)
        if appState.currentMode != .geminiLive {
            appState.switchMode(to: .geminiLive)
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        if appState.geminiLiveSession.isActive {
            appState.geminiLiveSession.stopSession()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        await appState.geminiLiveSession.startSession()
        return "Live session started."
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
