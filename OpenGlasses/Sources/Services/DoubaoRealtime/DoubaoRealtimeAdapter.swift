import Foundation

/// Doubao full duplex 3.0 uses X-Api-Key, session.create and batches of tool results.
///
/// The daily allowance (Plan NH) is not the adapter's: a Doubao session opens through
/// `RealtimeJSONSessionService.connect()`, which asks `LiveAllowanceGate` before any socket, and
/// `RealtimeSessionManager` meters it like every other live session.
final class DoubaoRealtimeAdapter: RealtimeProtocolAdapter {
    let profile = RealtimeProtocolProfile.doubaoDuplexV3
    let createsSessionOnOpen = true
    private var sessionCreated = false
    private var sessionConfiguration: [String: Any] = [:]
    private let model: String
    private let voice: String
    private var expectedCalls: Set<String> = []
    private var outputs: [String: String] = [:]
    private var deliveredCalls: Set<String> = []
    init(model: String, voice: String) { self.model = model; self.voice = voice }
    func reset() { sessionCreated = false; sessionConfiguration = [:]; expectedCalls.removeAll(); outputs.removeAll(); deliveredCalls.removeAll() }
    func encode(_ command: RealtimeCommand) throws -> [[String: Any]] {
        switch command {
        case .configure(let instructions, let tools):
            var session: [String: Any] = ["model": model, "instructions": instructions,
                "audio": ["input": ["format": ["type": "pcm", "rate": 16000]],
                          "output": ["format": ["type": "pcm_s16le", "rate": 24000], "voice": voice]]]
            if !tools.isEmpty { session["tools"] = tools }
            sessionConfiguration = session
            return [["type": sessionCreated ? "session.update" : "session.create", "session": session, "extension": ["asr": [:], "tts": [:], "dialog": [:]]]]
        case .audio(let data): return [["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]]
        case .image: throw RealtimeAdapterError.unsupportedOperation(String(localized: "images"))
        case .text: throw RealtimeAdapterError.unsupportedOperation(String(localized: "text injection"))
        case .updateContext(let instructions):
            sessionConfiguration["instructions"] = instructions
            // This API declares model/audio mandatory on session updates as well as creation.
            return [["type": "session.update", "session": sessionConfiguration]]
        case .speakText(let text):
            // Direct synthesis is distinct from a user query. Context is retained separately
            // by the engine's app-context lane; no invented user/assistant QA is necessary.
            return [["type": "speech_text_buffer.replacement.append", "text": text],
                    ["type": "speech_text_buffer.replacement.commit"]]
        case .toolResult(let id, let output):
            guard expectedCalls.contains(id) else { return [] }
            outputs[id] = output
            guard expectedCalls.allSatisfy({ outputs[$0] != nil }) else { return [] }
            let items: [[String: Any]] = expectedCalls.sorted().map {
                ["call_id": $0, "role": "tool", "content": [["type": "input_text", "text": outputs[$0]!]]]
            }
            expectedCalls.removeAll(); outputs.removeAll()
            // This protocol continues automatically after the complete result batch.
            return [["type": "conversation.item.create", "items": items]]
        case .interrupt: return [["type": "response.cancel"]]
        case .mute(let muted): return [["type": muted ? "input_audio_mute.commit" : "input_audio_unmute.commit"]]
        case .close: return [["type": "session.close"]]
        }
    }
    func decode(_ json: [String: Any]) -> [RealtimeEvent] {
        switch json["type"] as? String ?? "" {
        case "session.created", "session.updated": sessionCreated = true; return [.ready]
        case "session.closed": return [.closed]
        case "response.output_audio.delta":
            guard let delta = json["delta"] as? String, let data = Data(base64Encoded: delta) else { return [] }
            return [.audio(data, itemID: nil, contentIndex: 0)]
        case "response.output_text.delta": return (json["delta"] as? String).map { [.outputTranscript($0)] } ?? []
        case "response.output_audio.done": return [.speechFinished]
        case "conversation.item.input_audio_transcription.started": return [.userSpeaking(true)]
        case "conversation.item.input_audio_transcription.failed": return [.userSpeaking(false)]
        case "conversation.item.input_audio_transcription.completed":
            var result: [RealtimeEvent] = [.userSpeaking(false)]
            if let text = json["transcript"] as? String { result.append(.inputTranscript(text, complete: true)) }
            return result
        case "response.canceled": return [.interrupted]
        case "response.done": return [.turnComplete]
        case "response.function_call_arguments.done":
            let items = json["items"] as? [[String: Any]] ?? []
            var calls: [OpenAIRealtimeFunctionCall] = []
            for item in items {
                guard let id = item["call_id"] as? String, let name = item["name"] as? String,
                      deliveredCalls.insert(id).inserted else { continue }
                expectedCalls.insert(id)
                calls.append(.init(callId: id, name: name, argumentsJSON: item["arguments"] as? String ?? "{}"))
            }
            return calls.isEmpty ? [] : [.toolCalls(calls)]
        case "error":
            let error = json["error"] as? [String: Any] ?? json
            let code = String(describing: error["code"] ?? "")
            return [.failure(message: String(localized: "Doubao rejected the speech session. Check its API key, model version and voice."), retryable: code.hasPrefix("5"))]
        default: return []
        }
    }
}
