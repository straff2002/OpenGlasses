import Foundation
import UIKit

/// Exports all agent data as a portable zip bundle.
///
/// Export format (gateway-compatible):
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
///
/// The archive is the wearer's own agent documents, every memory they have stored and the full
/// text of every conversation — the single most concentrated copy of their data the app can
/// produce. It is therefore staged and returned exactly the way a clinical export is: a
/// `StagedExportLease` over a protected, backup-excluded session directory, with the plaintext
/// tree built *inside* that directory rather than in the shared temporary directory, so no
/// unprotected intermediate ever exists. Holding the lease is what keeps the archive; releasing
/// it — on share completion, cancellation, backgrounding or the next launch's scavenge — is what
/// removes it.
@MainActor
class AgentDataExporter {

    static func exportAll(
        agentDocs: AgentDocumentStore,
        memoryStore: SemanticMemoryStore,
        conversationStore: ConversationStore,
        coordinator: StagedExportCoordinator? = nil
    ) throws -> StagedExportLease {
        let coordinator = coordinator ?? .agentArchive
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(19)
        let exportName = "openglasses-export-\(timestamp)"

        let lease = try coordinator.makeLease(fileExtension: "zip",
                                              displayName: "\(exportName).zip",
                                              fallbackName: "openglasses-export.zip") { zipURL in
            let fm = FileManager.default
            // Staged inside the already-protected session directory, and named for the archive so
            // the ZIP's entries keep the folder the previous format documented.
            let stagingRoot = StagedExportCoordinator.stagingDirectory(for: zipURL)
            let tempDir = stagingRoot.appendingPathComponent(exportName, isDirectory: true)
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stagingRoot) }

            try writeBundle(into: tempDir,
                            agentDocs: agentDocs,
                            memoryStore: memoryStore,
                            conversationStore: conversationStore)

            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: tempDir, options: .forUploading,
                                   error: &coordinationError) { zipTempURL in
                do { try fm.copyItem(at: zipTempURL, to: zipURL) } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
        }

        // The archive's name and the entry names inside it are the wearer's own data by another
        // route — a conversation title becomes a filename. Only how much of each store went in.
        PrivacyLog.transfer(.agentExport, .exported,
                            count: conversationStore.threads.count,
                            total: memoryStore.memories.count)
        return lease
    }

    /// Write the readable bundle. Split out so the staging tree has exactly one producer and the
    /// lease path above stays about the lifecycle.
    private static func writeBundle(
        into tempDir: URL,
        agentDocs: AgentDocumentStore,
        memoryStore: SemanticMemoryStore,
        conversationStore: ConversationStore
    ) throws {
        let fm = FileManager.default

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
    }
}
