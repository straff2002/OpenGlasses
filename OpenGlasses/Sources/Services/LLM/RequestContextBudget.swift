import Foundation

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
    }

    struct CapacityError: LocalizedError {
        var errorDescription: String? {
            "The current question, equipment context or tool evidence is too large for this model. Your conversation and field session are saved. Narrow the manual lookup or choose a model with a larger context window."
        }
    }

    /// Exact IDs only. API product limits are deliberately not borrowed for Subscription.
    /// Source verified 2026-09-19: github.com/openai/codex, codex-rs/models-manager/models.json.
    /// Catalog defaults (272k), not optional max_context_window overrides (872k/1M).
    static func resolve(model: String, endpoint: String, catalogContext: Int? = nil) -> Limit {
        guard URL(string: endpoint)?.host == "chatgpt.com",
              URL(string: endpoint)?.path == "/backend-api/codex/responses" else {
            return Limit(context: 32_768, provenance: "unknownEndpointConservativeV1")
        }
        if let context = catalogContext, (8_192...2_000_000).contains(context) {
            return Limit(context: context, provenance: "accountCatalog")
        }
        let known: Set<String> = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4"]
        return known.contains(model)
            ? Limit(context: 272_000, provenance: "codexCatalog20260919")
            : Limit(context: 32_768, provenance: "unknownModelConservativeV1")
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
    static func build(model: String, instructions: String, history: [[String: Any]],
                      tools: [[String: Any]]?, protectedStart: Int, allowance: Int) throws -> Selection {
        let boundary = min(max(0, protectedStart), history.count)
        var selected = history
        // Retain every current-turn image; omit historical images before removing text.
        let historical = HistoryHygiene.pruneImages(Array(selected.prefix(boundary)), keepLast: 0)
        selected.replaceSubrange(0..<boundary, with: historical)
        var removed = 0
        while true {
            var prompt = instructions
            if removed > 0 {
                prompt += "\n\n[Working context: \(removed) older messages omitted. The saved transcript is unchanged. Do not infer missing results. Use field_session recall for older technician reports and task evidence; current session state takes precedence over older conversation.]"
            }
            let body = ResponsesTranslator.requestBody(model: model, instructions: prompt, history: selected, tools: tools)
            let estimate = estimate(body)
            if estimate.total <= allowance { return Selection(body: body, estimate: estimate, omittedMessages: removed) }
            let remainingOld = boundary - removed
            guard remainingOld > 0 else { throw CapacityError() }
            // Find the next real user exchange; a synthetic photo inside an older tool
            // exchange must not become a boundary and orphan its pending results.
            let next = (1..<remainingOld).first { index in
                selected[index]["role"] as? String == "user" && selected[index]["content"] is String
            } ?? remainingOld
            selected.removeFirst(next)
            removed += next
        }
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
        guard case LLMError.apiError(_, let status, let message) = error,
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

/// Account-specific catalog metadata is memory-only, expires, and cannot bleed across sign-ins.
@MainActor
enum ChatGPTContextCatalog {
    private static var account: String?
    private static var updatedAt: Date?
    private static var windows: [String: Int] = [:]

    static func update(data: Data, accountID: String?) {
        guard let accountID, !accountID.isEmpty else {
            account = nil
            updatedAt = nil
            windows = [:]
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
        account = accountID
        windows = parsed
        updatedAt = Date()
    }

    static func context(model: String, accountID: String?) -> Int? {
        guard account == accountID, let updatedAt, Date().timeIntervalSince(updatedAt) < 3_600 else { return nil }
        return windows[model]
    }
}
