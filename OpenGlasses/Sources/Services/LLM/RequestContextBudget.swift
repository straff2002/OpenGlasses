import Foundation
import CryptoKit

/// FM: accounting on the *translated* Responses request, not just the chat transcript.
/// Estimates intentionally err high: one UTF-8 byte per text token is an upper bound for
/// byte-level tokenizers; images use a fixed high-detail allowance, never base64 length.
/// The allowance is not a tokenizer guarantee; the bounded overflow retry remains necessary.
enum RequestContextBudget {
    struct Limit: Equatable {
        let context: Int
        let provenance: String
        var inputAllowance: Int { max(0, context - max(4_096, context / 8) - max(2_048, context / 20)) }
    }

    struct Estimate: Equatable {
        let instructions: Int
        let input: Int
        let tools: Int
        let framing: Int
        var total: Int { instructions + input + tools + framing }
    }

    struct Selection {
        let body: [String: Any]
        let estimate: Estimate
        let omittedMessages: Int
        /// Plan KK P3: true when the caller's `workingContext` would not fit beside the protected
        /// turn and the plain omission note was sent instead.
        var fellBackToPlainNote = false
    }

    struct CapacityError: LocalizedError {
        /// Whether a tool had already run in this user turn when the request would not fit.
        /// Before any tool, nothing has happened yet: another model may take the turn from the
        /// start. After one, restarting the turn elsewhere could repeat a state-changing tool, so
        /// the turn ends. Defaults to the safe reading.
        var toolsRanThisTurn = true

        var errorDescription: String? {
            "The current question, equipment context or tool evidence is too large for this model. Your conversation and field session are saved. Narrow the manual lookup or choose a model with a larger context window."
        }
    }

    /// Exact IDs only. API product limits are deliberately not borrowed for Subscription.
    /// Source verified 2026-09-19: github.com/openai/codex, codex-rs/models-manager/models.json.
    /// Catalog defaults (272k), not optional max_context_window overrides (872k/1M).
    ///
    /// Plan GC: the OpenAI API host (`api.openai.com`, any path) resolves from
    /// `openAIAPIContext(model:)` — the provider's per-model pages — and never borrows the
    /// subscription's 32k fallback. Azure (`*.openai.azure.com`) stays on the unknown-endpoint
    /// 32k: its limits are per deployment, and the deployment name need not be a model id.
    static func resolve(model: String, endpoint: String, catalogContext: Int? = nil) -> Limit {
        if URL(string: endpoint)?.host?.lowercased() == OpenAIRouteSelector.apiHost {
            return openAIAPIContext(model: model).map { Limit(context: $0, provenance: "openaiModelPages20260930") }
                ?? Limit(context: 128_000, provenance: "openaiUnknownModelConservativeV1")
        }
        guard URL(string: endpoint)?.host == "chatgpt.com",
              URL(string: endpoint)?.path == "/backend-api/codex/responses" else {
            return Limit(context: 32_768, provenance: "unknownEndpointConservativeV1")
        }
        if let context = catalogContext, (8_192...2_000_000).contains(context) {
            return Limit(context: context, provenance: "accountCatalog")
        }
        let known: Set<String> = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"]
        if known.contains(model) { return Limit(context: 272_000, provenance: "codexCatalog20260919") }
        // An id the table has not met yet but of the family the catalog serves (a new point
        // release, a variant suffix) takes the catalog's uniform default. 32k cannot even hold
        // the tool schemas, so the conservative value made every turn on such a model fail.
        if isCodexFamily(model) { return Limit(context: 272_000, provenance: "codexFamilyDefault20261015") }
        return Limit(context: 32_768, provenance: "unknownModelConservativeV1")
    }

    /// `gpt-5`, `gpt-5.x…`, `gpt-6…` and later majors: the generations the subscription catalog
    /// lists, every one of them at its 272k default. A shape outside it stays unknown.
    static func isCodexFamily(_ model: String) -> Bool {
        let id = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard id.hasPrefix("gpt-") else { return false }
        let rest = id.dropFirst(4)
        let major = rest.prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(major), number >= 5 else { return false }
        let next = rest.dropFirst(major.count).first
        return next == nil || next == "." || next == "-"
    }

    /// Context windows from the provider's model pages, read 2026-09-30, matched by prefix with
    /// the most specific first. nil for a model the table does not know.
    static func openAIAPIContext(model: String) -> Int? {
        let id = model.lowercased().trimmingCharacters(in: .whitespaces)
        let table: [(prefix: String, context: Int)] = [
            ("gpt-6", 1_050_000),
            ("gpt-5.6", 1_050_000),
            ("gpt-5.5", 1_050_000),
            ("gpt-5.4", 1_050_000),
            ("gpt-5.2", 400_000),
            ("gpt-5.1", 400_000),
            ("gpt-5", 400_000),       // gpt-5, -mini, -nano, -chat-latest
            ("gpt-4.1", 1_047_576),
            ("gpt-4o", 128_000),
            ("o4-mini", 200_000),
            ("o3", 200_000),
            ("o1", 200_000),
        ]
        return table.first { id.hasPrefix($0.prefix) }?.context
    }

    static func estimate(_ body: [String: Any]) -> Estimate {
        Estimate(instructions: weight(body["instructions"]), input: weight(body["input"]),
                 tools: weight(body["tools"]), framing: 256)
    }

    private static func weight(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "input_image" {
                // Prepared photos have a bounded resolution. 8k comfortably covers tiled
                // GPT high-detail and patch-based variants at the app's <=2576px edge.
                return 8_192
            }
            return 16 + dictionary.reduce(0) { $0 + $1.key.utf8.count + weight($1.value) }
        }
        if let array = value as? [Any] { return 8 + array.reduce(0) { $0 + weight($1) } }
        if let text = value as? String { return text.utf8.count + 4 }
        return 8
    }

    /// Drop only complete *older user exchanges*. The current user turn and every tool
    /// call/result since it are protected as a unit, including synthetic image messages.
    /// Instructions and schemas are never sliced: capacity failure is safer than losing a
    /// warning, a unit, or half of a function exchange. Selection only mutates request copies.
    ///
    /// `options` (Plan GC) are passed to `ResponsesTranslator.requestBody`, so the API route's
    /// trailing developer message and extra fields are inside the estimate; the default is the
    /// subscription body, unchanged.
    ///
    /// `recallOffered` (Plan KK) adds `APIHistoryBudget.recallSentence` to the omission note: true
    /// only when `tools` declares `brain` and the model may call it.
    ///
    /// `workingContext` (Plan KK P3) replaces the plain note: given how many messages this pass of
    /// the loop has removed, the text that follows the instructions (the conversation timeline,
    /// with or without the note), or nil for none. It is asked again every time `removed` grows,
    /// so the timeline is inside the estimate and follows the count actually sent. If even the
    /// protected turn alone will not fit beside it, the plain note is tried before giving up: the
    /// timeline is never the reason a turn fails.
    static func build(model: String, instructions: String, history: [[String: Any]],
                      tools: [[String: Any]]?, protectedStart: Int, allowance: Int,
                      options: ResponsesTranslator.RequestOptions = ResponsesTranslator.RequestOptions(),
                      recallOffered: Bool = false,
                      workingContext: ((_ removed: Int) -> String?)? = nil) throws -> Selection {
        let boundary = min(max(0, protectedStart), history.count)
        var selected = history
        // Retain every current-turn image; omit historical images before removing text.
        let historical = HistoryHygiene.pruneImages(Array(selected.prefix(boundary)), keepLast: 0)
        selected.replaceSubrange(0..<boundary, with: historical)
        let plainNote = { (removed: Int) in omissionNote(removed, recallOffered: recallOffered) }
        func makeBody(removed: Int, context: (Int) -> String?) -> [String: Any] {
            var prompt = instructions
            if let text = context(removed) { prompt += "\n\n" + text }
            return ResponsesTranslator.requestBody(model: model, instructions: prompt, history: selected,
                                                   tools: tools, options: options)
        }
        var removed = 0
        while true {
            let body = makeBody(removed: removed, context: workingContext ?? plainNote)
            let estimate = estimate(body)
            if estimate.total <= allowance { return Selection(body: body, estimate: estimate, omittedMessages: removed) }
            let remainingOld = boundary - removed
            guard remainingOld > 0 else {
                if workingContext != nil {
                    let plain = makeBody(removed: removed, context: plainNote)
                    let plainEstimate = Self.estimate(plain)
                    if plainEstimate.total <= allowance {
                        return Selection(body: plain, estimate: plainEstimate, omittedMessages: removed,
                                         fellBackToPlainNote: true)
                    }
                }
                throw CapacityError(toolsRanThisTurn: toolsRan(in: history, since: boundary))
            }
            let next = nextExchangeBoundary(in: selected, remainingOld: remainingOld)
            selected.removeFirst(next)
            removed += next
        }
    }

    /// The subscription's omission note, nil when nothing was removed. `partialNotes` (Plan KK P3)
    /// says the conversation timeline that follows does not cover everything removed.
    static func omissionNote(_ removed: Int, recallOffered: Bool, partialNotes: Bool = false) -> String? {
        guard removed > 0 else { return nil }
        let partial = partialNotes ? " " + APIHistoryBudget.partialNotesSentence : ""
        return "[Working context: \(removed) older messages omitted.\(partial) The saved transcript is unchanged. Do not infer missing results. Use field_session recall for older technician reports and task evidence; current session state takes precedence over older conversation.\(recallOffered ? " " + APIHistoryBudget.recallSentence : "")]"
    }

    /// Whether this turn's own messages (from `boundary` on) include a tool result — in the chat
    /// shape (`role: tool`) or as a raw Responses item.
    static func toolsRan(in history: [[String: Any]], since boundary: Int) -> Bool {
        guard boundary < history.count else { return false }
        return history[max(0, boundary)...].contains { message in
            message["role"] as? String == "tool" || message["type"] as? String == "function_call_output"
        }
    }

    /// How many leading messages make up the oldest complete user exchange: up to the next real
    /// user turn (a user message whose content is plain text). A synthetic photo inside an older
    /// tool exchange must not become a boundary and orphan its pending results. Shared with
    /// `APIHistoryBudget` (Plan GB P5), so both budgets cut history at the same seams.
    static func nextExchangeBoundary(in history: [[String: Any]], remainingOld: Int) -> Int {
        guard remainingOld > 1 else { return max(0, remainingOld) }
        return (1..<remainingOld).first { index in
            history[index]["role"] as? String == "user" && history[index]["content"] is String
        } ?? remainingOld
    }

    static func isOverflow(code: String?, message: String?) -> Bool {
        if let code, !code.isEmpty {
            return ["context_length_exceeded", "context_window_exceeded", "max_context_length_exceeded"].contains(code.lowercased())
        }
        let text = message?.lowercased() ?? ""
        return text.contains("exceeded model context window size")
            || text.contains("maximum context length")
            || text.contains("input exceeds the context window")
            || text.contains("context window exceeded")
    }

    static func isOverflow(error: Error) -> Bool {
        guard case LLMError.apiError(_, let status, let message, _) = error,
              [200, 400, 413].contains(status) else { return false }
        if let data = message?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let details = object["error"] as? [String: Any] ?? object
            return isOverflow(code: details["code"] as? String,
                              message: details["message"] as? String ?? details["detail"] as? String)
        }
        return isOverflow(code: nil, message: message)
    }
}

/// Account-specific catalog context windows. Persisted (model ids and integers, keyed by a digest
/// of the account, never the account id itself) so a relaunch keeps a catalog-only model's real
/// window instead of dropping to the conservative default until someone opens the model picker.
/// A snapshot serves for `maxAge`, is refreshed in the background once older than `refreshAfter`,
/// and cannot bleed across sign-ins: a different account, or none, reads nothing.
@MainActor
enum ChatGPTContextCatalog {
    /// How long a stored window is trusted at all.
    static let maxAge: TimeInterval = 7 * 24 * 3_600
    /// How old a snapshot may get before a ChatGPT turn asks for a fresh one, without waiting.
    static let refreshAfter: TimeInterval = 3_600
    static let storeKey = "chatGPTContextCatalog.v1"
    /// Injectable so tests never touch the app's own defaults.
    static var store: UserDefaults = .standard

    /// A failed fetch is not retried on every turn: one attempt per `retryAfter`.
    static let retryAfter: TimeInterval = 300
    private static var lastRefreshAttempt: Date?

    /// Set when the backend refused a model as outside the account's catalog: the stored copy is
    /// known to be wrong, so the next turn fetches a fresh one whatever its age.
    private static var markedStale = false

    struct Snapshot: Codable, Equatable {
        let accountDigest: String
        let updatedAt: Date
        let windows: [String: Int]
        /// Which models the account offers. Optional so a snapshot stored before it existed still
        /// decodes; such a snapshot says nothing about availability.
        var offered: ChatGPTModelAvailability.Catalog?
    }

    static func update(data: Data, accountID: String?, now: Date = Date()) {
        guard let accountID, !accountID.isEmpty else {
            store.removeObject(forKey: storeKey)
            markedStale = false
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let rows = object["models"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
        var parsed: [String: Int] = [:]
        for row in rows {
            guard let id = row["slug"] as? String ?? row["id"] as? String ?? row["model"] as? String,
                  let window = row["context_window"] as? Int ?? row["contextWindow"] as? Int,
                  (8_192...2_000_000).contains(window) else { continue }
            parsed[id] = window
        }
        let snapshot = Snapshot(accountDigest: digest(accountID), updatedAt: now, windows: parsed,
                                offered: ChatGPTModelAvailability.Catalog(data: data))
        if let encoded = try? JSONEncoder().encode(snapshot) {
            store.set(encoded, forKey: storeKey)
        }
        markedStale = false
    }

    /// The models this account's stored catalog offers, or nil when there is no usable snapshot
    /// for it (none, another account's, too old, or stored before availability was kept).
    static func offered(accountID: String?, now: Date = Date()) -> ChatGPTModelAvailability.Catalog? {
        guard let snapshot = snapshot(for: accountID),
              now.timeIntervalSince(snapshot.updatedAt) < maxAge else { return nil }
        return snapshot.offered
    }

    /// Ask the next ChatGPT turn to fetch the catalog again, however recent the stored copy.
    static func markStale() {
        markedStale = true
    }

    static func context(model: String, accountID: String?, now: Date = Date()) -> Int? {
        guard let snapshot = snapshot(for: accountID),
              now.timeIntervalSince(snapshot.updatedAt) < maxAge else { return nil }
        return snapshot.windows[model]
    }

    /// True when this account has no snapshot, or one older than `refreshAfter`.
    static func needsRefresh(accountID: String?, now: Date = Date()) -> Bool {
        guard let accountID, !accountID.isEmpty else { return false }
        guard !markedStale, let snapshot = snapshot(for: accountID) else { return true }
        return now.timeIntervalSince(snapshot.updatedAt) >= refreshAfter
    }

    /// Fetch the catalog in the background when the snapshot is missing or old. Never awaited by
    /// a turn: this turn uses what is stored, the next one gets the fresh window.
    static func refreshIfStale(accountID: String?, now: Date = Date()) {
        guard needsRefresh(accountID: accountID, now: now) else { return }
        if let last = lastRefreshAttempt, now.timeIntervalSince(last) < retryAfter { return }
        lastRefreshAttempt = now
        Task { @MainActor in
            _ = await ModelFetcher.fetchChatGPTCatalog()
        }
    }

    private static func snapshot(for accountID: String?) -> Snapshot? {
        guard let accountID, !accountID.isEmpty,
              let data = store.data(forKey: storeKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.accountDigest == digest(accountID) else { return nil }
        return snapshot
    }

    private static func digest(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
