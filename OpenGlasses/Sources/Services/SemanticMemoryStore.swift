import Foundation
import NaturalLanguage
import SQLite3

/// Semantic memory store — the app's persistent user memory (the live `userMemory` instance).
///
/// Supersedes an earlier flat key-value JSON store (whose `user_memories.json` it still migrates on
/// first run via `migrateFromLegacyJSONIfNeeded`). Upgrades over that flat store:
/// - SQLite backing with full history (nothing is truly deleted — tombstoned)
/// - On-device NLEmbedding vectors for semantic search (NLEmbedding, iOS 13+)
/// - Topics auto-detected from content (health, work, people, places, preferences…)
/// - Timestamps on every entry; optional expiry
/// - Agent diary: separate append-only log of agent observations
///
/// Public API mirrors the legacy key-value store it replaced, so all call sites work unchanged.
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

    // MARK: - Published (legacy key-value compat — in-memory caches)

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
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let docsDir: URL
    private let maxGlobalChars = 3000
    private let maxPersonaChars = 1500
    private let maxGatewayResults = 10

    /// Routed through the shared [[Embedder]] seam (sentence model preferred over the old word-average,
    /// and the transformer `NLContextualEmbedding` when enabled) instead of a raw `NLEmbedding`. Stored
    /// vectors carry a version stamp ([[EmbeddingVersion]]) so a model change re-embeds on access.
    private let embedder = Embedder()

    // MARK: - Init

    /// `directory` is injectable so tests can point at a temp folder instead of the app's documents.
    init(directory: URL? = nil) {
        docsDir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        openDatabase()
        createTables()
        migrateFromLegacyJSONIfNeeded()
        refreshGlobalCache()
        PrivacyLog.store(.semanticMemory, .opened, scope: .global, count: memories.count)
    }

    // MARK: - Public API (legacy key-value compatible)

    /// Returns false when the write did not reach the database — callers at a tool/spoken
    /// boundary should say so rather than claim the fact was saved.
    @discardableResult
    func remember(_ key: String, value: String) -> Bool {
        let k = normalise(key)
        guard !k.isEmpty, !value.isEmpty else { return false }
        let ns = activePersonaId ?? "global"
        if activePersonaId != nil {
            if personaMemories[k] == value { return true }
            guard upsert(key: k, value: value, namespace: ns) else {
                PrivacyLog.store(.semanticMemory, .writeFailed, scope: .persona)
                return false
            }
            refreshPersonaCache()
            trim(namespace: ns, maxChars: maxPersonaChars)
            PrivacyLog.store(.semanticMemory, .recordWritten, scope: .persona,
                             characters: value.count)
        } else {
            if memories[k] == value { return true }
            guard upsert(key: k, value: value, namespace: "global") else {
                PrivacyLog.store(.semanticMemory, .writeFailed, scope: .global)
                return false
            }
            refreshGlobalCache()
            trim(namespace: "global", maxChars: maxGlobalChars)
            PrivacyLog.store(.semanticMemory, .recordWritten, scope: .global,
                             characters: value.count)
        }
        pushToGateway(key: k, value: value)
        return true
    }

    @discardableResult
    func rememberGlobal(_ key: String, value: String) -> Bool {
        let k = normalise(key)
        guard !k.isEmpty, !value.isEmpty else { return false }
        if memories[k] == value { return true }
        guard upsert(key: k, value: value, namespace: "global") else {
            PrivacyLog.store(.semanticMemory, .writeFailed, scope: .global)
            return false
        }
        refreshGlobalCache()
        trim(namespace: "global", maxChars: maxGlobalChars)
        PrivacyLog.store(.semanticMemory, .recordWritten, scope: .global,
                         characters: value.count)
        pushToGateway(key: k, value: value)
        return true
    }

    @discardableResult
    func forget(_ key: String) -> Bool {
        let k = normalise(key)
        let ok: Bool
        if let pid = activePersonaId {
            ok = deleteMemory(key: k, namespace: pid)
            refreshPersonaCache()
        } else {
            ok = deleteMemory(key: k, namespace: "global")
            refreshGlobalCache()
        }
        return ok
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
        PrivacyLog.store(.semanticMemory, .cleared)
    }

    func clearPersonaMemories() {
        guard let pid = activePersonaId else { return }
        personaMemories.removeAll()
        run("DELETE FROM memories WHERE namespace = ?", [.text(pid)])
        PrivacyLog.store(.semanticMemory, .cleared, scope: .persona)
    }

    // MARK: - System Prompt Context

    func systemPromptContext() -> String? {
        systemPromptContext(query: nil)
    }

    /// BK P2 — bound the memory block so it can't silently balloon the prompt past the on-device
    /// budget as the store grows. Every branch is capped: at most `maxMemoryLines` entries per
    /// section (the semantic-hit path was already limited to 8; these caps extend the same
    /// discipline to the sorted global fallback, persona, and gateway paths, which previously
    /// dumped the *entire* store), and each value is clamped to `maxValueChars`.
    static let maxMemoryLines = 8
    static let maxValueChars = 300

    private static func clampValue(_ value: String) -> String {
        guard value.count > maxValueChars else { return value }
        return String(value.prefix(maxValueChars)) + "…"
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
            if let q = query, !q.isEmpty, embedder.isAvailable {
                let results = semanticSearch(query: q, limit: Self.maxMemoryLines, namespace: "global")
                pairs = results.isEmpty
                    ? memories.sorted { $0.key < $1.key }
                    : results.map { ($0.keyName, $0.value) }
            } else {
                // No query / embedder unavailable / retrieval off: previously dumped the whole
                // store. Clamp to the same cap so a large global store can't overflow the budget.
                pairs = memories.sorted { $0.key < $1.key }
            }
            let lines = pairs.prefix(Self.maxMemoryLines).map { "- \($0.0): \(Self.clampValue($0.1))" }
            sections.append("SHARED MEMORY (facts about the user — reference naturally):\n\(lines.joined(separator: "\n"))")
        }

        if hasPersona, let pid = activePersonaId {
            let lines = personaMemories.sorted { $0.key < $1.key }
                .prefix(Self.maxMemoryLines)
                .map { "- \($0.key): \(Self.clampValue($0.value))" }
            sections.append("PERSONA MEMORY (\(pid)):\n\(lines.joined(separator: "\n"))")
        }

        if hasGateway {
            let lines = gatewayMemories.prefix(Self.maxMemoryLines).map { "- \(Self.clampValue($0))" }
            sections.append("GATEWAY MEMORY (other devices):\n\(lines.joined(separator: "\n"))")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Semantic Search (new)

    /// Search memories by meaning. Falls back to keyword scoring if no embedding model.
    /// `namespace: nil` searches EVERY namespace — including other personas' scoped memory —
    /// so callers at a chat boundary must pass an explicit scope (see the `namespaces:` overload).
    func semanticSearch(query: String, limit: Int = 5, namespace: String? = nil) -> [SearchResult] {
        scoreSearch(query: query, limit: limit, rows: fetchAllMemories(namespace: namespace))
    }

    /// Search memories restricted to an explicit set of namespaces (project scope, Plan AN).
    /// A scoped chat passes `["global", activePersonaId]` so it sees shared memory plus its own
    /// persona, but never another persona's remembered facts.
    func semanticSearch(query: String, limit: Int = 5, namespaces: [String]) -> [SearchResult] {
        scoreSearch(query: query, limit: limit, rows: fetchAllMemories(namespaces: namespaces))
    }

    private func scoreSearch(query: String, limit: Int, rows: [MemoryEntry]) -> [SearchResult] {
        let queryVec = embed(query)
        let current = embedder.version

        let scored: [(MemoryEntry, Float)] = rows.map { row in
            if let qv = queryVec, let stored = fetchEmbedding(key: row.keyName, namespace: row.namespace) {
                // Re-embed a memory left by an older model (or unstamped legacy word-average) and
                // persist the result, so memory recall self-heals after a model swap.
                let vec: [Float]?
                switch EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: stored.version), current: current) {
                case .reuse:
                    vec = stored.vec
                case .reembed:
                    if let fresh = embed("\(row.keyName) \(row.value)") {
                        writeMemoryEmbedding(id: row.id, vec: fresh)
                        vec = fresh
                    } else { vec = nil }
                }
                if let v = vec { return (row, cosineSimilarity(qv, v)) }
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
        run("INSERT INTO diary (id, text, created_at) VALUES (?, ?, ?)",
            [.text(id), .text(text), .real(now)])
        // Store embedding (+ version stamp) for later search
        if let vec = embed(text) {
            writeDiaryEmbedding(id: id, vec: vec)
        }
        PrivacyLog.store(.semanticMemory, .appended, characters: text.count,
                         detail: PrivacyToken("diary"))
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
        let current = embedder.version
        var all: [(DiaryEntry, Float)] = []
        var pending: [(id: String, vec: [Float])] = []   // re-embeds to persist after the read finalizes
        var stmt: OpaquePointer?
        let sql = "SELECT id, text, created_at, embedding, embedding_version FROM diary ORDER BY created_at DESC LIMIT 200"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let text = String(cString: sqlite3_column_text(stmt, 1))
            let ts = sqlite3_column_double(stmt, 2)
            let entry = DiaryEntry(id: id, text: text, createdAt: Date(timeIntervalSince1970: ts))
            let storedVersion = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil
            var sim: Float = 0
            if let ptr = sqlite3_column_blob(stmt, 3) {
                let len = sqlite3_column_bytes(stmt, 3)
                let data = Data(bytes: ptr, count: Int(len))
                switch EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: storedVersion), current: current) {
                case .reuse:
                    sim = cosineSimilarity(qv, dataToVec(data))
                case .reembed:
                    // Recompute against the active model; defer the write-back until the read statement
                    // is finalized (don't mutate the table while iterating this cursor).
                    if let fresh = embed(text) {
                        sim = cosineSimilarity(qv, fresh)
                        pending.append((id, fresh))
                    }
                }
            }
            all.append((entry, sim))
        }
        sqlite3_finalize(stmt)
        for p in pending { writeDiaryEmbedding(id: p.id, vec: p.vec) }
        return all.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    // MARK: - AI Response Parsing (legacy key-value compat)

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

    // MARK: - Gateway Sync (legacy key-value compat)

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

    // MARK: - Char Usage (legacy key-value compat)

    var globalCharUsage: Int { memories.reduce(0) { $0 + $1.key.count + $1.value.count } }
    var personaCharUsage: Int { personaMemories.reduce(0) { $0 + $1.key.count + $1.value.count } }

    // MARK: - Private: SQLite Setup

    private var dbURL: URL { docsDir.appendingPathComponent("semantic_memory.sqlite") }

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            PrivacyLog.store(.semanticMemory, .openFailed,
                             error: .sqlite(code: sqlite3_errcode(db),
                                            extended: sqlite3_extended_errcode(db)))
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
        // Embedding version stamp (see [[EmbeddingVersion]]). Deliberately NOT backfilled: existing
        // vectors were produced by the old raw word-average `NLEmbedding`, which differs from the
        // `Embedder` seam now in use — so they read as outdated (NULL) and re-embed on next access.
        exec("ALTER TABLE memories ADD COLUMN embedding_version TEXT")
        exec("ALTER TABLE diary ADD COLUMN embedding_version TEXT")
    }

    // MARK: - Private: CRUD

    @discardableResult
    private func upsert(key: String, value: String, namespace: String) -> Bool {
        let id = "\(namespace):\(key)"
        let topic = detectTopic(key: key, value: value)
        let now = Date().timeIntervalSince1970
        let ok = run("""
        INSERT INTO memories (id, key_name, value, topic, namespace, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(key_name, namespace) DO UPDATE SET
            value = excluded.value,
            topic = excluded.topic,
            created_at = excluded.created_at,
            embedding = NULL
        """, [.text(id), .text(key), .text(value), .text(topic), .text(namespace), .real(now)])
        guard ok else { return false }
        // Compute and store embedding (+ version stamp) synchronously (fast for short texts).
        if let vec = embed("\(key) \(value)") {
            writeMemoryEmbedding(id: id, vec: vec)
        }
        return true
    }

    @discardableResult
    private func deleteMemory(key: String, namespace: String) -> Bool {
        run("DELETE FROM memories WHERE key_name = ? AND namespace = ?",
            [.text(key), .text(namespace)])
    }

    private func fetchAllMemories(namespace: String? = nil) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        var stmt: OpaquePointer?
        let sql: String
        if namespace != nil {
            sql = "SELECT id, key_name, value, topic, namespace, created_at, expires_at FROM memories WHERE namespace = ?"
        } else {
            sql = "SELECT id, key_name, value, topic, namespace, created_at, expires_at FROM memories"
        }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return entries }
        defer { sqlite3_finalize(stmt) }
        if let ns = namespace {
            sqlite3_bind_text(stmt, 1, ns, -1, SQLITE_TRANSIENT)
        }
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

    /// Fetch memories across an explicit set of namespaces (deduped). An empty set matches nothing,
    /// which is the safe default — never fall through to "all namespaces" here.
    private func fetchAllMemories(namespaces: [String]) -> [MemoryEntry] {
        let unique = Array(Set(namespaces))
        guard !unique.isEmpty else { return [] }
        var entries: [MemoryEntry] = []
        var stmt: OpaquePointer?
        let placeholders = unique.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, key_name, value, topic, namespace, created_at, expires_at FROM memories WHERE namespace IN (\(placeholders))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return entries }
        defer { sqlite3_finalize(stmt) }
        for (i, ns) in unique.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), ns, -1, SQLITE_TRANSIENT)
        }
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

    private func fetchEmbedding(key: String, namespace: String) -> (vec: [Float], version: String?)? {
        var stmt: OpaquePointer?
        let sql = "SELECT embedding, embedding_version FROM memories WHERE key_name = ? AND namespace = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, namespace, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL,
              let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        let len = sqlite3_column_bytes(stmt, 0)
        let version = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 1)) : nil
        return (dataToVec(Data(bytes: ptr, count: Int(len))), version)
    }

    /// Persist a memory's embedding + current version stamp (initial write or lazy re-embed).
    private func writeMemoryEmbedding(id: String, vec: [Float]) {
        let sql = "UPDATE memories SET embedding = ?, embedding_version = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let data = vecToData(vec)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
        sqlite3_bind_text(stmt, 2, embedder.version.tag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    /// Persist a diary entry's embedding + current version stamp.
    private func writeDiaryEmbedding(id: String, vec: [Float]) {
        let sql = "UPDATE diary SET embedding = ?, embedding_version = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let data = vecToData(vec)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
        sqlite3_bind_text(stmt, 2, embedder.version.tag, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(stmt)
    }

    // MARK: - Embedding migration

    /// Stored memories embedded by a model other than the active one (or unstamped legacy
    /// word-average vectors). They re-embed on next search; this is for diagnostics / tests.
    var outdatedMemoryCount: Int {
        let current = embedder.version
        var stmt: OpaquePointer?
        let sql = "SELECT embedding_version FROM memories WHERE embedding IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var n = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let v = sqlite3_column_type(stmt, 0) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 0)) : nil
            if EmbeddingMigrationPolicy.action(stored: EmbeddingVersion(tag: v), current: current) == .reembed { n += 1 }
        }
        return n
    }

    /// Force every stored vector (memories + diary) to be treated as outdated by clearing its stamp,
    /// so the next search re-embeds it with the active model. The honest way to invalidate after a
    /// model change.
    func invalidateEmbeddings() {
        exec("UPDATE memories SET embedding_version = NULL")
        exec("UPDATE diary SET embedding_version = NULL")
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
        // The pool, not the persona: a namespace is a persona id, which is a small wearer-visible
        // set that a hash would not anonymise.
        let isGlobal = namespace == "global"
        let rows = fetchAllMemories(namespace: namespace)
        var total = rows.reduce(0) { $0 + $1.keyName.count + $1.value.count }
        guard total > maxChars else { return }
        let sorted = rows.sorted { ($0.keyName.count + $0.value.count) < ($1.keyName.count + $1.value.count) }
        for row in sorted {
            guard total > maxChars else { break }
            total -= row.keyName.count + row.value.count
            deleteMemory(key: row.keyName, namespace: namespace)
            PrivacyLog.store(.semanticMemory, .evicted, scope: isGlobal ? .global : .persona,
                             characters: row.keyName.count + row.value.count)
        }
        if namespace == "global" { refreshGlobalCache() }
        else { refreshPersonaCache() }
    }

    // MARK: - Private: Migration

    private func migrateFromLegacyJSONIfNeeded() {
        let legacyURL = docsDir.appendingPathComponent("user_memories.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            // Transient read/decode failure — leave the file for a later attempt.
            return
        }

        // Migrate only into an empty semantic DB; either way, retire the legacy file so it can
        // never re-import. (It used to linger forever: `clearAll()` + relaunch resurrected every
        // "forgotten" memory from it.)
        if !dict.isEmpty, fetchAllMemories(namespace: "global").isEmpty {
            PrivacyLog.store(.semanticMemory, .migrated, scope: .global, count: dict.count)
            for (key, value) in dict { upsert(key: key, value: value, namespace: "global") }
            refreshGlobalCache()
        }
        let retired = legacyURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: retired)
        do {
            try FileManager.default.moveItem(at: legacyURL, to: retired)
            PrivacyLog.store(.semanticMemory, .legacyRetired)
        } catch {
            PrivacyLog.store(.semanticMemory, .legacyRetireFailed,
                             error: SafeErrorSummary(error))
        }
    }

    // MARK: - Private: Embedding

    private func embed(_ text: String) -> [Float]? { embedder.embed(text) }

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

    /// A value bound into a parameterized statement — the only safe way to put user/LLM text
    /// into SQL. (Interpolating escaped strings broke on apostrophes in memory *keys*, which
    /// were never escaped: `[REMEMBER: daughter's birthday = …]` silently failed to save.)
    private enum SQLValue {
        case text(String)
        case real(Double)
    }

    /// Run a parameterized (non-query) statement with positional `?` binds.
    @discardableResult
    private func run(_ sql: String, _ binds: [SQLValue]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            PrivacyLog.store(.semanticMemory, .queryFailed, detail: PrivacyToken("prepare"),
                             error: .sqlite(code: sqlite3_errcode(db),
                                            extended: sqlite3_extended_errcode(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch bind {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            }
        }
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        if !ok {
            PrivacyLog.store(.semanticMemory, .queryFailed, detail: PrivacyToken("step"),
                             error: .sqlite(code: sqlite3_errcode(db),
                                            extended: sqlite3_extended_errcode(db)))
        }
        return ok
    }

    private func normalise(_ key: String) -> String {
        key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
