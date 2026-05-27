import Foundation

/// AI-managed persistent user memory with per-persona isolation.
///
/// Hierarchical memory model (inspired by NanoClaw):
///   - **Global** memories: shared across all personas (user facts like name, city, preferences)
///   - **Persona** memories: isolated per persona (conversation style, persona-specific context)
///
/// When a persona is active, the system prompt receives global + persona memories.
/// When no persona is active, only global memories are injected.
///
/// Storage format: JSON files per namespace.
///   - `user_memories.json` — global (shared) memories
///   - `user_memories_{personaId}.json` — per-persona memories
///
/// The AI manages this via structured commands in its responses:
///   - `[REMEMBER: key = value]` — stores in current namespace (persona if active, else global)
///   - `[REMEMBER_GLOBAL: key = value]` — always stores in global namespace
///   - `[FORGET: key]` — removes from current namespace
@MainActor
class UserMemoryStore: ObservableObject {
    @Published var memories: [String: String] = [:]
    @Published var personaMemories: [String: String] = [:]
    @Published var gatewayMemories: [String] = []

    /// Currently active persona ID for memory isolation
    var activePersonaId: String? {
        didSet {
            if oldValue != activePersonaId {
                loadPersonaMemories()
            }
        }
    }

    /// Reference to OpenClaw bridge for cross-device memory sync.
    weak var openClawBridge: OpenClawBridge?

    private let docsDir: URL
    private let maxGatewayResults = 10

    /// Character budget for memories (replaces fixed count limit).
    /// Encourages the AI to consolidate verbose entries rather than hoard short ones.
    private let maxGlobalChars = 3000
    private let maxPersonaChars = 1500

    /// Turn counter for periodic memory nudge.
    /// After every `nudgeInterval` user turns, the system injects a hidden review prompt
    /// asking the LLM to evaluate whether anything worth remembering was shared.
    private(set) var turnsSinceLastNudge = 0
    let nudgeInterval = 8

    init() {
        docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        loadGlobal()
    }

    private var globalStorageURL: URL {
        docsDir.appendingPathComponent("user_memories.json")
    }

    private func personaStorageURL(for personaId: String) -> URL {
        docsDir.appendingPathComponent("user_memories_\(personaId).json")
    }

    // MARK: - CRUD

    /// Store or update a memory in the current namespace (persona if active, else global).
    func remember(_ key: String, value: String) {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !value.isEmpty else { return }

        if activePersonaId != nil {
            // Skip exact duplicates
            if personaMemories[normalizedKey] == value { return }
            personaMemories[normalizedKey] = value
            trimByCharBudget(dict: &personaMemories, maxChars: maxPersonaChars)
            savePersona()
            NSLog("[Memory] Persona stored: %@ = %@", normalizedKey, value)
        } else {
            if memories[normalizedKey] == value { return }
            memories[normalizedKey] = value
            trimByCharBudget(dict: &memories, maxChars: maxGlobalChars)
            saveGlobal()
            NSLog("[Memory] Global stored: %@ = %@", normalizedKey, value)
        }
        pushToGateway(key: normalizedKey, value: value)
    }

    /// Store a memory in the global namespace regardless of active persona.
    func rememberGlobal(_ key: String, value: String) {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !value.isEmpty else { return }
        if memories[normalizedKey] == value { return }
        memories[normalizedKey] = value
        trimByCharBudget(dict: &memories, maxChars: maxGlobalChars)
        saveGlobal()
        NSLog("[Memory] Global stored: %@ = %@", normalizedKey, value)
        pushToGateway(key: normalizedKey, value: value)
    }

    /// Forget a specific memory from current namespace (tries persona first, then global).
    func forget(_ key: String) {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if activePersonaId != nil, personaMemories.removeValue(forKey: normalizedKey) != nil {
            savePersona()
            NSLog("[Memory] Persona forgot: %@", normalizedKey)
        } else if memories.removeValue(forKey: normalizedKey) != nil {
            saveGlobal()
            NSLog("[Memory] Global forgot: %@", normalizedKey)
        }
    }

    /// Recall a specific memory (checks persona first, then global).
    func recall(_ key: String) -> String? {
        let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return personaMemories[normalizedKey] ?? memories[normalizedKey]
    }

    /// Clear all memories (global + current persona).
    func clearAll() {
        memories.removeAll()
        personaMemories.removeAll()
        saveGlobal()
        savePersona()
        NSLog("[Memory] Cleared all memories")
    }

    /// Clear only the current persona's memories.
    func clearPersonaMemories() {
        personaMemories.removeAll()
        savePersona()
        NSLog("[Memory] Cleared persona memories")
    }

    // MARK: - Gateway Memory Sync

    /// Push a memory to the gateway for cross-device recall (fire-and-forget).
    private func pushToGateway(key: String, value: String) {
        // HIPAA: never sync memories to external gateway — PHI must stay on-device
        guard !Config.hipaaMode else { return }
        guard let bridge = openClawBridge, bridge.connectionState == .connected else { return }
        let persona = activePersonaId
        Task {
            var metadata: [String: String] = ["key": key, "source": "openglasses"]
            if let persona { metadata["persona"] = persona }
            _ = await bridge.storeMemory(content: "\(key): \(value)", metadata: metadata)
        }
    }

    /// Pull relevant memories from the gateway. Call at connect time or before LLM queries.
    func syncFromGateway(query: String? = nil) async {
        // HIPAA: no external memory access
        guard !Config.hipaaMode else { return }
        guard let bridge = openClawBridge, bridge.connectionState == .connected else { return }
        let q = query ?? "user preferences facts context"
        let result = await bridge.queryMemory(query: q, limit: maxGatewayResults)
        switch result {
        case .success(let text) where !text.isEmpty && text != "No memory results":
            gatewayMemories = text.components(separatedBy: "\n---\n").filter { !$0.isEmpty }
            NSLog("[Memory] Synced %d gateway memories", gatewayMemories.count)
        default:
            break
        }
    }

    // MARK: - System Prompt Injection

    /// Generate a memory context string to inject into the system prompt.
    /// Includes global memories, persona memories, and gateway memories when available.
    func systemPromptContext() -> String? {
        let hasGlobal = !memories.isEmpty
        let hasPersona = !personaMemories.isEmpty
        let hasGateway = !gatewayMemories.isEmpty

        guard hasGlobal || hasPersona || hasGateway else { return nil }

        var sections: [String] = []

        if hasGlobal {
            let lines = memories.sorted(by: { $0.key < $1.key }).map { "- \($0.key): \($0.value)" }
            sections.append("SHARED MEMORY (facts about the user — reference naturally):\n\(lines.joined(separator: "\n"))")
        }

        if hasPersona, let personaId = activePersonaId {
            let lines = personaMemories.sorted(by: { $0.key < $1.key }).map { "- \($0.key): \($0.value)" }
            sections.append("PERSONA MEMORY (\(personaId) — your personal context):\n\(lines.joined(separator: "\n"))")
        }

        if hasGateway {
            let lines = gatewayMemories.map { "- \($0)" }
            sections.append("GATEWAY MEMORY (from your other devices — may overlap with above):\n\(lines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - AI Response Parsing

    /// Parse memory commands from an AI response.
    /// Commands: [REMEMBER: key = value], [REMEMBER_GLOBAL: key = value], [FORGET: key]
    /// Returns the response with commands stripped out.
    func parseAndExecuteCommands(in response: String) -> String {
        var cleaned = response

        // Each phase re-scans `cleaned` so removals from earlier phases don't
        // invalidate ranges captured against the original input.
        cleaned = applyKeyValueCommands(
            in: cleaned,
            pattern: #"\[REMEMBER_GLOBAL:\s*(.+?)\s*=\s*(.+?)\]"#,
            sideEffect: rememberGlobal
        )
        cleaned = applyKeyValueCommands(
            in: cleaned,
            pattern: #"\[REMEMBER:\s*(.+?)\s*=\s*(.+?)\]"#,
            sideEffect: remember
        )
        cleaned = applyKeyCommands(
            in: cleaned,
            pattern: #"\[FORGET:\s*(.+?)\]"#,
            sideEffect: forget
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyKeyValueCommands(
        in text: String,
        pattern: String,
        sideEffect: (String, String) -> Void
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            if let keyRange = Range(match.range(at: 1), in: text),
               let valueRange = Range(match.range(at: 2), in: text) {
                sideEffect(String(text[keyRange]), String(text[valueRange]))
            }
            if let fullRange = Range(match.range, in: result) {
                result.removeSubrange(fullRange)
            }
        }
        return result
    }

    private func applyKeyCommands(
        in text: String,
        pattern: String,
        sideEffect: (String) -> Void
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            if let keyRange = Range(match.range(at: 1), in: text) {
                sideEffect(String(text[keyRange]))
            }
            if let fullRange = Range(match.range, in: result) {
                result.removeSubrange(fullRange)
            }
        }
        return result
    }

    // MARK: - Persistence

    private func saveGlobal() {
        do {
            let data = try JSONEncoder().encode(memories)
            try data.write(to: globalStorageURL, options: .atomic)
        } catch {
            NSLog("[Memory] Global save failed: %@", error.localizedDescription)
        }
    }

    private func loadGlobal() {
        guard FileManager.default.fileExists(atPath: globalStorageURL.path) else { return }
        do {
            let data = try Data(contentsOf: globalStorageURL)
            memories = try JSONDecoder().decode([String: String].self, from: data)
            NSLog("[Memory] Loaded %d global memories", memories.count)
        } catch {
            NSLog("[Memory] Global load failed: %@", error.localizedDescription)
        }
    }

    private func savePersona() {
        guard let personaId = activePersonaId else { return }
        do {
            let data = try JSONEncoder().encode(personaMemories)
            try data.write(to: personaStorageURL(for: personaId), options: .atomic)
        } catch {
            NSLog("[Memory] Persona save failed: %@", error.localizedDescription)
        }
    }

    private func loadPersonaMemories() {
        guard let personaId = activePersonaId else {
            personaMemories.removeAll()
            return
        }
        let url = personaStorageURL(for: personaId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            personaMemories.removeAll()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            personaMemories = try JSONDecoder().decode([String: String].self, from: data)
            NSLog("[Memory] Loaded %d persona memories for %@", personaMemories.count, personaId)
        } catch {
            NSLog("[Memory] Persona load failed: %@", error.localizedDescription)
            personaMemories.removeAll()
        }
    }

    /// Trim memories by total character budget rather than fixed count.
    /// Evicts the shortest entries first (they're least information-dense).
    private func trimByCharBudget(dict: inout [String: String], maxChars: Int) {
        var totalChars = dict.reduce(0) { $0 + $1.key.count + $1.value.count }
        guard totalChars > maxChars else { return }

        // Evict shortest entries first (least info density)
        let sorted = dict.sorted { ($0.key.count + $0.value.count) < ($1.key.count + $1.value.count) }
        for entry in sorted {
            guard totalChars > maxChars else { break }
            totalChars -= entry.key.count + entry.value.count
            dict.removeValue(forKey: entry.key)
            NSLog("[Memory] Evicted (over char budget): %@", entry.key)
        }
    }

    // MARK: - Memory Nudge

    /// Increment the turn counter after each user message.
    /// Returns true when a nudge review should be triggered.
    func incrementTurnAndCheckNudge() -> Bool {
        turnsSinceLastNudge += 1
        if turnsSinceLastNudge >= nudgeInterval {
            turnsSinceLastNudge = 0
            return true
        }
        return false
    }

    /// The hidden prompt injected after N turns to trigger memory review.
    static let nudgePrompt = """
    [SYSTEM: Memory Review — This is an automated check, not from the user. \
    Review the recent conversation: has the user revealed personal details, preferences, \
    corrections, or facts worth remembering? If yes, emit [REMEMBER: key = value] commands. \
    If a previous memory is now wrong, emit [FORGET: key] first, then the correction. \
    If nothing is worth remembering, do nothing — do NOT mention this review to the user.]
    """

    /// Current total character usage for display/diagnostics.
    var globalCharUsage: Int {
        memories.reduce(0) { $0 + $1.key.count + $1.value.count }
    }

    var personaCharUsage: Int {
        personaMemories.reduce(0) { $0 + $1.key.count + $1.value.count }
    }
}
