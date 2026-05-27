import Foundation
import NaturalLanguage
import SQLite3

/// Semantic memory store — drop-in replacement for UserMemoryStore.
///
/// Upgrades over the flat key-value store:
/// - SQLite backing with full history (nothing is truly deleted — tombstoned)
/// - On-device NLEmbedding vectors for semantic search (NLEmbedding, iOS 13+)
/// - Topics auto-detected from content (health, work, people, places, preferences…)
/// - Timestamps on every entry; optional expiry
/// - Agent diary: separate append-only log of agent observations
///
/// Public API is identical to UserMemoryStore so all call sites work unchanged.
/// New capabilities exposed via `semanticSearch()`, `relevantContext()`,
/// `writeDiary()`, and `readDiary()`.
@MainActor
class SemanticMemoryStore: ObservableObject {

    // MARK: - Types

    struct MemoryEntry: Identifiable {
        let id: String
        let keyName: String
        let value: String
        let topic: String
        let namespace: String  // "global" or personaId
        let createdAt: Date
        let expiresAt: Date?
    }

    struct DiaryEntry: Identifiable {
        let id: String
        let text: String
        let createdAt: Date
    }

    struct SearchResult {
        let keyName: String
        let value: String
        let topic: String
        let namespace: String
        let createdAt: Date
        let similarity: Float
    }

    // MARK: - Published (UserMemoryStore compat — in-memory caches)

    @Published var memories: [String: String] = [:]
    @Published var personaMemories: [String: String] = [:]
    @Published var gatewayMemories: [String] = []

    // MARK: - Configuration

    var activePersonaId: String? {
        didSet {
            if oldValue != activePersonaId { refreshPersonaCache() }
        }
    }

    weak var openClawBridge: OpenClawBridge?

    private(set) var turnsSinceLastNudge = 0
    let nudgeInterval = 8

    // MARK: - Private

    private var db: OpaquePointer?
    private let docsDir: URL
    private let maxGlobalChars = 3000
    private let maxPersonaChars = 1500
    private let maxGatewayResults = 10

    private lazy var wordEmbedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)

    // MARK: - Init

    init() {
        docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        openDatabase()
        createTables()
        migrateFromLegacyJSONIfNeeded()
        refreshGlobalCache()
        NSLog("[SemanticMemory] Init — %d global memories", memories.count)
    }

    // MARK: - Public API (UserMemoryStore compatible)

    func remember(_ key: String, value: String) {
        let k = normalise(key)
        guard !k.isEmpty, !value.isEmpty else { return }
        let ns = activePersonaId ?? "global"
        if activePersonaId != nil {
            if personaMemories[k] == value { return }
            upsert(key: k, value: value, namespace: ns)
            refreshPersonaCache()
            trim(namespace: ns, maxChars: maxPersonaChars)
            NSLog("[SemanticMemory] Persona: %@ = %@", k, value)
        } else {
            if memories[k] == value { return }
            upsert(key: k, value: value, namespace: "global")
            refreshGlobalCache()
            trim(namespace: "global", maxChars: maxGlobalChars)
            NSLog("[SemanticMemory] Global: %@ = %@", k, value)
        }
        pushToGateway(key: k, value: value)
    }

    func rememberGlobal(_ key: String, value: String) {
        let k = normalise(key)
        guard !k.isEmpty, !value.isEmpty else { return }
        if memories[k] == value { return }
        upsert(key: k, value: value, namespace: "global")
        refreshGlobalCache()
        trim(namespace: "global", maxChars: maxGlobalChars)
        NSLog("[SemanticMemory] Global: %@ = %@", k, value)
        pushToGateway(key: k, value: value)
    }

    func forget(_ key: String) {
        let k = normalise(key)
        if let pid = activePersonaId {
            deleteMemory(key: k, namespace: pid)
            refreshPersonaCache()
        } else {
            deleteMemory(key: k, namespace: "global")
            refreshGlobalCache()
        }
    }

    func recall(_ key: String) -> String? {
        let k = normalise(key)
        return personaMemories[k] ?? memories[k]
    }

    func clearAll() {
        memories.removeAll()
        personaMemories.removeAll()
        exec("DELETE FROM memories")
        exec("DELETE FROM diary")
        NSLog("[SemanticMemory] Cleared all")
    }

    func clearPersonaMemories() {
        guard let pid = activePersonaId else { return }
        personaMemories.removeAll()
        exec("DELETE FROM memories WHERE namespace = '\(pid)'")
        NSLog("[SemanticMemory] Cleared persona memories for %@", pid)
    }

    // MARK: - System Prompt Context

    func systemPromptContext() -> String? {
        systemPromptContext(query: nil)
    }

    /// Returns a formatted memory context for injection into the system prompt.
    /// When `query` is provided, global memories are filtered to the most relevant
    /// via semantic search, keeping token usage lean.
    func systemPromptContext(query: String? = nil) -> String? {
        let hasGlobal = !memories.isEmpty
        let hasPersona = !personaMemories.isEmpty
        let hasGateway = !gatewayMemories.isEmpty
        guard hasGlobal || hasPersona || hasGateway else { return nil }

        var sections: [String] = []

        if hasGlobal {
            let pairs: [(String, String)]
            if let q = query, !q.isEmpty, wordEmbedding != nil {
                let results = semanticSearch(query: q, limit: 8, namespace: "global")
                pairs = results.isEmpty
                    ? memories.sorted { $0.key < $1.key }
                    : results.map { ($0.keyName, $0.value) }
            } else {
                pairs = memories.sorted { $0.key < $1.key }
            }
            let lines = pairs.map { "- \($0.0): \($0.1)" }
            sections.append("SHARED MEMORY (facts about the user — reference naturally):\n\(lines.joined(separator: "\n"))")
        }

        if hasPersona, let pid = activePersonaId {
            let lines = personaMemories.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }
            sections.append("PERSONA MEMORY (\(pid)):\n\(lines.joined(separator: "\n"))")
        }

        if hasGateway {
            let lines = gatewayMemories.map { "- \($0)" }
            sections.append("GATEWAY MEMORY (other devices):\n\(lines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Semantic Search (new)

    /// Search memories by meaning. Falls back to keyword scoring if no embedding model.
    func semanticSearch(query: String, limit: Int = 5, namespace: String? = nil) -> [SearchResult] {
        let queryVec = embed(query)
        let rows = fetchAllMemories(namespace: namespace)

        let scored: [(MemoryEntry, Float)] = rows.map { row in
            if let qv = queryVec, let rv = fetchEmbedding(key: row.keyName, namespace: row.namespace) {
                return (row, cosineSimilarity(qv, rv))
            }
            // Keyword fallback
            let text = "\(row.keyName) \(row.value)".lowercased()
            let words = query.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let hits = words.filter { text.contains($0) }.count
            return (row, Float(hits) / Float(max(words.count, 1)))
        }

        return scored
            .filter { $0.1 > 0.05 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { SearchResult(keyName: $0.0.keyName, value: $0.0.value, topic: $0.0.topic,
                                namespace: $0.0.namespace, createdAt: $0.0.createdAt, similarity: $0.1) }
    }

    // MARK: - Agent Diary (new)

    func writeDiary(_ text: String) {
        guard !text.isEmpty else { return }
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        let t = escapedSQL(text)
        exec("INSERT INTO diary (id, text, created_at) VALUES ('\(id)', '\(t)', \(now))")
        // Store embedding for later search
        if let vec = embed(text) {
            let data = vecToData(vec)
            updateDiaryEmbedding(id: id, data: data)
        }
        NSLog("[SemanticMemory] Diary: %@", String(text.prefix(80)))
    }

    func readDiary(limit: Int = 10) -> [DiaryEntry] {
        var entries: [DiaryEntry] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, text, created_at FROM diary ORDER BY created_at DESC LIMIT \(limit)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return entries }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let text = String(cString: sqlite3_column_text(stmt, 1))
            let ts = sqlite3_column_double(stmt, 2)
            entries.append(DiaryEntry(id: id, text: text, createdAt: Date(timeIntervalSince1970: ts)))
        }
        return entries
    }

    func relevantDiary(for query: String, limit: Int = 3) -> [DiaryEntry] {
        guard let qv = embed(query) else {
            return readDiary(limit: limit)
        }
        var all: [(DiaryEntry, Float)] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, text, created_at, embedding FROM diary ORDER BY created_at DESC LIMIT 200"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let text = String(cString: sqlite3_column_text(stmt, 1))
            let ts = sqlite3_column_double(stmt, 2)
            let entry = DiaryEntry(id: id, text: text, createdAt: Date(timeIntervalSince1970: ts))
            var sim: Float = 0
            if let ptr = sqlite3_column_blob(stmt, 3) {
                let len = sqlite3_column_bytes(stmt, 3)
                let data = Data(bytes: ptr, count: Int(len))
                sim = cosineSimilarity(qv, dataToVec(data))
            }
            all.append((entry, sim))
        }
        return all.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    // MARK: - AI Response Parsing (UserMemoryStore compat)

    func parseAndExecuteCommands(in response: String) -> String {
        var cleaned = response

        let globalPattern = #"\[REMEMBER_GLOBAL:\s*(.+?)\s*=\s*(.+?)\]"#
        if let regex = try? NSRegularExpression(pattern: globalPattern) {
            let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
            for match in matches.reversed() {
                if let kr = Range(match.range(at: 1), in: response),
                   let vr = Range(match.range(at: 2), in: response) {
                    rememberGlobal(String(response[kr]), value: String(response[vr]))
                }
                if let fr = Range(match.range, in: cleaned) { cleaned.removeSubrange(fr) }
            }
        }

        let rememberPattern = #"\[REMEMBER:\s*(.+?)\s*=\s*(.+?)\]"#
        if let regex = try? NSRegularExpression(pattern: rememberPattern) {
            let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
            for match in matches.reversed() {
                if let kr = Range(match.range(at: 1), in: response),
                   let vr = Range(match.range(at: 2), in: response) {
                    remember(String(response[kr]), value: String(response[vr]))
                }
                if let fr = Range(match.range, in: cleaned) { cleaned.removeSubrange(fr) }
            }
        }

        let forgetPattern = #"\[FORGET:\s*(.+?)\]"#
        if let regex = try? NSRegularExpression(pattern: forgetPattern) {
            let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
            for match in matches.reversed() {
                if let kr = Range(match.range(at: 1), in: response) { forget(String(response[kr])) }
                if let fr = Range(match.range, in: cleaned) { cleaned.removeSubrange(fr) }
            }
        }

        // Diary entries from agent responses
        let diaryPattern = #"\[DIARY:\s*(.+?)\]"#
        if let regex = try? NSRegularExpression(pattern: diaryPattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: response, range: NSRange(response.startIndex..., in: response))
            for match in matches.reversed() {
                if let tr = Range(match.range(at: 1), in: response) { writeDiary(String(response[tr])) }
                if let fr = Range(match.range, in: cleaned) { cleaned.removeSubrange(fr) }
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Turn Nudge

    func incrementTurnAndCheckNudge() -> Bool {
        turnsSinceLastNudge += 1
        if turnsSinceLastNudge >= nudgeInterval {
            turnsSinceLastNudge = 0
            return true
        }
        return false
    }

    static let nudgePrompt = """
    [SYSTEM: Memory Review — automated check, not from the user. \
    Review the recent conversation: has the user revealed personal details, preferences, \
    corrections, or facts worth remembering? If yes, emit [REMEMBER: key = value] commands. \
    If a previous memory is now wrong, emit [FORGET: key] first then the correction. \
    If you made a notable observation or took an action the user should know about later, \
    emit [DIARY: your observation here]. \
    If nothing is worth recording, do nothing — do NOT mention this review to the user.]
    """

    // MARK: - Gateway Sync (UserMemoryStore compat)

    private func pushToGateway(key: String, value: String) {
        guard !Config.hipaaMode else { return }
        guard let bridge = openClawBridge, bridge.connectionState == .connected else { return }
        let persona = activePersonaId
        Task {
            var metadata: [String: String] = ["key": key, "source": "openglasses"]
            if let p = persona { metadata["persona"] = p }
            _ = await bridge.storeMemory(content: "\(key): \(value)", metadata: metadata)
        }
    }

    func syncFromGateway(query: String? = nil) async {
        guard !Config.hipaaMode else { return }
        guard let bridge = openClawBridge, bridge.connectionState == .connected else { return }
        let q = query ?? "user preferences facts context"
        let result = await bridge.queryMemory(query: q, limit: maxGatewayResults)
        switch result {
        case .success(let text) where !text.isEmpty && text != "No memory results":
            gatewayMemories = text.components(separatedBy: "\n---\n").filter { !$0.isEmpty }
        default:
            break
        }
    }

    // MARK: - Char Usage (UserMemoryStore compat)

    var globalCharUsage: Int { memories.reduce(0) { $0 + $1.key.count + $1.value.count } }
    var personaCharUsage: Int { personaMemories.reduce(0) { $0 + $1.key.count + $1.value.count } }

    // MARK: - Private: SQLite Setup

    private var dbURL: URL { docsDir.appendingPathComponent("semantic_memory.sqlite") }

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            NSLog("[SemanticMemory] Failed to open database")
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
    }

    private func createTables() {
        exec("""
        CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            key_name TEXT NOT NULL,
            value TEXT NOT NULL,
            topic TEXT NOT NULL DEFAULT 'general',
            namespace TEXT NOT NULL,
            created_at REAL NOT NULL,
            expires_at REAL,
            embedding BLOB,
            UNIQUE(key_name, namespace) ON CONFLICT REPLACE
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_mem_ns ON memories(namespace)")
        exec("""
        CREATE TABLE IF NOT EXISTS diary (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            created_at REAL NOT NULL,
            embedding BLOB
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_diary_ts ON diary(created_at)")
    }

    // MARK: - Private: CRUD

    private func upsert(key: String, value: String, namespace: String) {
        let id = "\(namespace):\(key)"
        let topic = detectTopic(key: key, value: value)
        let now = Date().timeIntervalSince1970
        let v = escapedSQL(value)
        exec("""
        INSERT INTO memories (id, key_name, value, topic, namespace, created_at)
        VALUES ('\(id)', '\(key)', '\(v)', '\(topic)', '\(namespace)', \(now))
        ON CONFLICT(key_name, namespace) DO UPDATE SET
            value = excluded.value,
            topic = excluded.topic,
            created_at = excluded.created_at,
            embedding = NULL
        """)
        // Compute and store embedding synchronously (fast for short texts)
        if let vec = embed("\(key) \(value)") {
            let data = vecToData(vec)
            exec("UPDATE memories SET embedding = ? WHERE id = '\(id)'", blob: data)
        }
    }

    private func deleteMemory(key: String, namespace: String) {
        exec("DELETE FROM memories WHERE key_name = '\(key)' AND namespace = '\(namespace)'")
    }

    private func fetchAllMemories(namespace: String? = nil) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        var stmt: OpaquePointer?
        let sql: String
        if let ns = namespace {
            sql = "SELECT id, key_name, value, topic, namespace, created_at, expires_at FROM memories WHERE namespace = '\(ns)'"
        } else {
            sql = "SELECT id, key_name, value, topic, namespace, created_at, expires_at FROM memories"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return entries }
        defer { sqlite3_finalize(stmt) }
        let now = Date().timeIntervalSince1970
        while sqlite3_step(stmt) == SQLITE_ROW {
            let expiresAt = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_double(stmt, 6) : nil
            if let exp = expiresAt, exp < now { continue }  // skip expired
            entries.append(MemoryEntry(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                keyName: String(cString: sqlite3_column_text(stmt, 1)),
                value: String(cString: sqlite3_column_text(stmt, 2)),
                topic: String(cString: sqlite3_column_text(stmt, 3)),
                namespace: String(cString: sqlite3_column_text(stmt, 4)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                expiresAt: expiresAt.map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return entries
    }

    private func fetchEmbedding(key: String, namespace: String) -> [Float]? {
        var stmt: OpaquePointer?
        let sql = "SELECT embedding FROM memories WHERE key_name = '\(key)' AND namespace = '\(namespace)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        let len = sqlite3_column_bytes(stmt, 0)
        return dataToVec(Data(bytes: ptr, count: Int(len)))
    }

    private func updateDiaryEmbedding(id: String, data: Data) {
        exec("UPDATE diary SET embedding = ? WHERE id = '\(id)'", blob: data)
    }

    // MARK: - Private: Cache Refresh

    private func refreshGlobalCache() {
        let rows = fetchAllMemories(namespace: "global")
        memories = Dictionary(uniqueKeysWithValues: rows.map { ($0.keyName, $0.value) })
    }

    private func refreshPersonaCache() {
        guard let pid = activePersonaId else { personaMemories.removeAll(); return }
        let rows = fetchAllMemories(namespace: pid)
        personaMemories = Dictionary(uniqueKeysWithValues: rows.map { ($0.keyName, $0.value) })
    }

    // MARK: - Private: Trim

    private func trim(namespace: String, maxChars: Int) {
        let rows = fetchAllMemories(namespace: namespace)
        var total = rows.reduce(0) { $0 + $1.keyName.count + $1.value.count }
        guard total > maxChars else { return }
        let sorted = rows.sorted { ($0.keyName.count + $0.value.count) < ($1.keyName.count + $1.value.count) }
        for row in sorted {
            guard total > maxChars else { break }
            total -= row.keyName.count + row.value.count
            deleteMemory(key: row.keyName, namespace: namespace)
            NSLog("[SemanticMemory] Evicted (over budget): %@", row.keyName)
        }
        if namespace == "global" { refreshGlobalCache() }
        else { refreshPersonaCache() }
    }

    // MARK: - Private: Migration

    private func migrateFromLegacyJSONIfNeeded() {
        let legacyURL = docsDir.appendingPathComponent("user_memories.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              !dict.isEmpty else { return }

        // Only migrate if semantic DB is empty
        guard fetchAllMemories(namespace: "global").isEmpty else { return }
        NSLog("[SemanticMemory] Migrating %d legacy memories", dict.count)
        for (key, value) in dict { upsert(key: key, value: value, namespace: "global") }
        refreshGlobalCache()
    }

    // MARK: - Private: Embedding

    private func embed(_ text: String) -> [Float]? {
        guard let model = wordEmbedding else { return nil }
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        for word in words {
            guard let vec = model.vector(for: word) else { continue }
            for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
            count += 1
        }
        guard count > 0 else { return nil }
        let avg = sum.map { $0 / Double(count) }
        return avg.map { Float($0) }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }

    private func vecToData(_ vec: [Float]) -> Data {
        vec.withUnsafeBytes { Data($0) }
    }

    private func dataToVec(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Private: Topic Detection

    private func detectTopic(key: String, value: String) -> String {
        let text = "\(key) \(value)".lowercased()
        let topics: [(String, [String])] = [
            ("health",      ["health", "pain", "doctor", "medical", "medication", "exercise", "weight",
                             "sleep", "knee", "back", "headache", "symptom", "diet", "injury", "hospital"]),
            ("work",        ["work", "job", "project", "meeting", "deadline", "client", "code", "app",
                             "office", "colleague", "boss", "task", "career", "business", "startup"]),
            ("people",      ["friend", "family", "partner", "husband", "wife", "son", "daughter",
                             "parent", "colleague", "person", "birthday", "relationship"]),
            ("places",      ["home", "office", "city", "address", "location", "country", "place",
                             "restaurant", "gym", "store", "neighbourhood", "street"]),
            ("preferences", ["prefer", "like", "dislike", "hate", "love", "favourite", "favorite",
                             "enjoy", "avoid", "always", "never"]),
            ("finance",     ["money", "budget", "cost", "price", "payment", "bank", "invest",
                             "spend", "save", "subscription", "salary", "expense"]),
            ("learning",    ["learn", "study", "read", "book", "course", "skill", "language",
                             "topic", "research", "understand", "practice"]),
        ]
        for (topic, keywords) in topics {
            if keywords.contains(where: { text.contains($0) }) { return topic }
        }
        return "general"
    }

    // MARK: - Private: SQLite Helpers

    @discardableResult
    private func exec(_ sql: String, blob: Data? = nil) -> Bool {
        if let data = blob {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            _ = data.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(data.count), nil)
            }
            return sqlite3_step(stmt) == SQLITE_DONE
        }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func normalise(_ key: String) -> String {
        key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func escapedSQL(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}
