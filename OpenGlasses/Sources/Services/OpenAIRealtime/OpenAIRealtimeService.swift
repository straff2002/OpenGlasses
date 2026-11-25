import Foundation

// Compatibility entry point for existing callers and saved OpenAI shortcuts.
typealias OpenAIRealtimeConnectionState = RealtimeConnectionState

@MainActor
class OpenAIRealtimeService: RealtimeJSONSessionService {
    func configure(apiKey: String, model: String, systemInstruction: String,
                   toolDeclarations: [[String: Any]] = []) {
        configure(connection: .init(endpoint: RealtimeConnectionConfiguration.openAIEndpoint,
                                    apiKey: apiKey, model: model, isCustom: false),
                  systemInstruction: systemInstruction, toolDeclarations: toolDeclarations)
    }
    func configure(connection: RealtimeConnectionConfiguration, systemInstruction: String,
                   toolDeclarations: [[String: Any]] = []) {
        super.configure(model: .init(id: "legacy", name: "OpenAI Realtime",
                                    providerID: connection.isCustom ? "compatible" : "openai",
                                    profileID: (connection.isCustom ? RealtimeProtocolProfile.openAIBetaV1
                                                 : .openAIRealtimeV1).rawValue,
                                    endpoint: connection.endpoint, apiKey: connection.apiKey,
                                    model: connection.model, voice: ""),
                        systemInstruction: systemInstruction, toolDeclarations: toolDeclarations)
    }
    override func connect() async -> Bool {
        guard MedicalEgressGuard.allows(.openAIRealtimeSession) else {
            connectionState = .error(MedicalEgressRefusal.userMessage)
            return false
        }
        // Plan NH: checked here before the shared connect checks it again for every protocol.
        if let line = LiveAllowanceGate.check() {
            connectionState = .error(line)
            return false
        }
        return await super.connect()
    }
    nonisolated static func sessionUpdate(instructions: String, tools: [[String: Any]]) -> [String: Any] {
        OpenAIRealtimeAdapter.sessionUpdate(instructions: instructions, tools: tools)
    }
}
