import Foundation
import UIKit

/// Exports all agent data as a portable zip bundle.
///
/// Export format (OpenClaw/nanoclaw compatible):
/// ```
/// openglasses-export-{date}/
/// ├── soul.md
/// ├── skills.md
/// ├── memory.md
/// ├── user_memories.json
/// ├── conversations/
/// │   └── {thread-id}.json
/// ├── quick_actions.json
/// └── config.json (non-sensitive settings)
/// ```
@MainActor
class AgentDataExporter {

    static func exportAll(
        agentDocs: AgentDocumentStore,
        memoryStore: UserMemoryStore,
        conversationStore: ConversationStore
    ) throws -> URL {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(19)
        let exportName = "openglasses-export-\(timestamp)"
        let tempDir = fm.temporaryDirectory.appendingPathComponent(exportName)

        // Create export directory
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Agent documents
        try agentDocs.soul.write(to: tempDir.appendingPathComponent("soul.md"), atomically: true, encoding: .utf8)
        try agentDocs.skills.write(to: tempDir.appendingPathComponent("skills.md"), atomically: true, encoding: .utf8)
        try agentDocs.memory.write(to: tempDir.appendingPathComponent("memory.md"), atomically: true, encoding: .utf8)

        // User memories (key-value store)
        let memoriesData = try JSONEncoder().encode(memoryStore.memories)
        try memoriesData.write(to: tempDir.appendingPathComponent("user_memories.json"))

        // Conversations
        let convoDir = tempDir.appendingPathComponent("conversations")
        try fm.createDirectory(at: convoDir, withIntermediateDirectories: true)
        for thread in conversationStore.threads {
            let data = try JSONEncoder().encode(thread)
            try data.write(to: convoDir.appendingPathComponent("\(thread.id).json"))
        }

        // Quick actions
        let actions = Config.quickActions
        let actionsData = try JSONEncoder().encode(actions)
        try actionsData.write(to: tempDir.appendingPathComponent("quick_actions.json"))

        // Non-sensitive config summary
        let configSummary: [String: Any] = [
            "exportDate": Date().description,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "agentModeEnabled": Config.agentModeEnabled,
            "silentMode": Config.silentMode,
            "wakePhrase": Config.wakePhrase,
            "modelTier": Config.modelTier.rawValue,
            "locale": Locale.current.language.languageCode?.identifier ?? "en",
            "conversationCount": conversationStore.threads.count,
            "memoryCount": memoryStore.memories.count,
        ]
        let configData = try JSONSerialization.data(withJSONObject: configSummary, options: .prettyPrinted)
        try configData.write(to: tempDir.appendingPathComponent("config.json"))

        // Create zip
        let zipURL = fm.temporaryDirectory.appendingPathComponent("\(exportName).zip")
        try? fm.removeItem(at: zipURL)  // Clean previous

        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &error) { zipTempURL in
            try? fm.copyItem(at: zipTempURL, to: zipURL)
        }

        if let error { throw error }

        // Clean up temp directory
        try? fm.removeItem(at: tempDir)

        NSLog("[Export] Created: %@", zipURL.lastPathComponent)
        return zipURL
    }
}
