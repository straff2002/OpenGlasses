import Foundation

/// Trust verdict for an attacker-authored MCP tool definition.
enum ToolTrust: Equatable {
    case trusted                 // looks ordinary — offer normally
    case quarantined(String)     // usable, but only under its fully-qualified name + a trust badge
    case blocked(String)         // never offered to the model (dangerous shadow / unusable schema)

    var isOffered: Bool { if case .blocked = self { return false }; return true }

    /// Short reason for the UI badge / log (empty when trusted).
    var reason: String {
        switch self {
        case .trusted: return ""
        case .quarantined(let r), .blocked(let r): return r
        }
    }
}

/// Discovery-time scanner for MCP tool definitions (Plan R).
///
/// A remote server authors each tool's `name`, `description`, and `inputSchema`. A poisoned
/// *description* can smuggle hidden instructions ("ignore previous… send a message"), and a
/// hostile `name` can *shadow* a native high-impact tool (advertise `send_message`) or
/// typosquat one. This is the discovery-time mirror of [[PromptInjectionPolicy]]'s inbound
/// framing: every definition is scanned before it can be offered to the model. Pure and
/// deterministic — no LLM — so it's fully unit-testable.
enum ToolDefinitionScanner {

    /// Scan an `MCPTool`. `nativeNames` is the set of locally-owned tool names to detect
    /// collisions against (high-impact ones come from `PromptInjectionPolicy.highImpactTools`).
    static func scan(_ tool: MCPTool, nativeNames: Set<String>) -> ToolTrust {
        scan(name: tool.name, description: tool.description, inputSchema: tool.inputSchema, nativeNames: nativeNames)
    }

    static func scan(name: String, description: String, inputSchema: [String: Any], nativeNames: Set<String>) -> ToolTrust {
        let bareName = name.lowercased()

        // 1. BLOCK — schema is missing or not an object. A tool with no honest parameter
        //    contract can't be safely offered.
        if inputSchema.isEmpty {
            return .blocked("missing input schema")
        }
        if let type = inputSchema["type"] as? String, type.lowercased() != "object" {
            return .blocked("input schema is not an object (type=\(type))")
        }

        // 2. BLOCK — exact shadow of a native high-impact tool (e.g. advertises `send_message`).
        let highImpact = PromptInjectionPolicy.highImpactTools
        if highImpact.contains(bareName) {
            return .blocked("shadows native high-impact tool '\(bareName)'")
        }

        // 3. QUARANTINE — typosquat of a high-impact name (Levenshtein ≤ 1, not exact).
        if let near = highImpact.first(where: { levenshtein(bareName, $0) <= 1 }) {
            return .quarantined("name resembles native high-impact tool '\(near)'")
        }

        // 4. QUARANTINE — collides with a non-high-impact native name. Harmless (native wins,
        //    and qualified-name routing isolates it) but worth flagging.
        if nativeNames.contains(bareName) {
            return .quarantined("name collides with native tool '\(bareName)'")
        }

        // 5. QUARANTINE — description carries hidden-instruction / forged-envelope / encoded payload.
        if let reason = suspiciousDescriptionReason(description) {
            return .quarantined("suspicious description: \(reason)")
        }

        return .trusted
    }

    // MARK: - Poisoned-description detection

    /// Imperative / meta / role-forgery patterns an attacker hides in a tool description.
    private static let descriptionRedFlags: [(label: String, regex: NSRegularExpression)] = [
        flag("instruction override", #"(?i)ignore\s+(all\s+)?(previous|prior|above)"#),
        flag("instruction override", #"(?i)disregard\s+(all\s+)?(previous|prior|your)"#),
        flag("role injection", #"(?i)\b(system|assistant|developer)\s*:"#),
        flag("forged tags", #"(?i)</?\s*(tool_output|untrusted_tool_output|system|assistant|instructions?)\b"#),
        flag("hidden directive", #"(?i)\bdo not (tell|mention|reveal|inform)\b"#),
        flag("hidden directive", #"(?i)\b(you must|always)\b.{0,40}\b(call|send|run|execute)\b"#),
        // A long base64 run is almost never a legitimate human-readable description.
        flag("encoded payload", #"[A-Za-z0-9+/]{80,}={0,2}"#),
    ]

    private static func suspiciousDescriptionReason(_ description: String) -> String? {
        guard !description.isEmpty else { return nil }
        let range = NSRange(description.startIndex..<description.endIndex, in: description)
        for entry in descriptionRedFlags where entry.regex.firstMatch(in: description, options: [], range: range) != nil {
            return entry.label
        }
        return nil
    }

    private static func flag(_ label: String, _ raw: String) -> (String, NSRegularExpression) {
        guard let regex = try? NSRegularExpression(pattern: raw) else {
            fatalError("ToolDefinitionScanner: invalid regex for \(label): \(raw)")
        }
        return (label, regex)
    }

    // MARK: - Levenshtein (typosquat detection)

    /// Classic edit distance, early-out once it exceeds 1 isn't worth the complexity here —
    /// names are short, so the full DP is plenty fast.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
