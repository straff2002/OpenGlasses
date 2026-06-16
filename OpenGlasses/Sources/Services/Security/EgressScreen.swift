import Foundation

/// Per-server outbound policy for arguments sent to an external MCP tool.
/// Default is `.redact` — proceed, but never let plaintext secrets/PII leave the device.
enum EgressPolicy: String, Codable, CaseIterable, Identifiable {
    case block    // fail closed: withhold the call entirely on any sensitive hit
    case redact   // mask the sensitive spans, then proceed (default)
    case allow    // proceed unmodified, but record what was sent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .block:  return "Block"
        case .redact: return "Redact"
        case .allow:  return "Allow"
        }
    }

    var detail: String {
        switch self {
        case .block:  return "Withhold the call if arguments contain secrets or PII"
        case .redact: return "Mask secrets/PII, then send"
        case .allow:  return "Send unmodified (logged)"
        }
    }
}

/// The decision for one outbound tool call. Every case carries the patterns that fired
/// (`hits`), so the caller can log the decision regardless of policy.
enum EgressVerdict {
    case allow(hits: [String])                      // hits empty ⇒ clean; non-empty ⇒ allowed despite a hit
    case redact(args: [String: Any], hits: [String]) // safe copy of args + what was masked
    case block(reason: String, hits: [String])      // human-readable reason; no network call made

    var hits: [String] {
        switch self {
        case .allow(let h), .block(_, let h): return h
        case .redact(_, let h): return h
        }
    }

    var isBlocked: Bool { if case .block = self { return true }; return false }
    var redactedArgs: [String: Any]? { if case .redact(let a, _) = self { return a }; return nil }
    var blockReason: String? { if case .block(let r, _) = self { return r }; return nil }
}

/// Deterministic pre-call screen over an outbound argument dictionary (Plan R).
///
/// A pure function of `(arguments, EgressPolicy)` — no I/O, no LLM — so it's fully
/// unit-testable and runs in well under a millisecond, adding no perceptible latency to a
/// tool call. It walks every string leaf of `arguments` (recursing nested dicts/arrays) and
/// applies [[SecretPatterns]]. This is the outbound mirror of [[PromptInjectionPolicy]]'s
/// inbound framing: inbound MCP output is enveloped as untrusted data; outbound args are
/// screened so a third-party server can't be handed the user's API keys or health-vault text.
enum EgressScreen {

    static func evaluate(_ arguments: [String: Any], policy: EgressPolicy) -> EgressVerdict {
        let hits = dedup(collectHits(in: arguments))
        guard !hits.isEmpty else { return .allow(hits: []) }

        switch policy {
        case .allow:
            return .allow(hits: hits)
        case .block:
            return .block(reason: "withheld — arguments contain \(hits.joined(separator: ", "))", hits: hits)
        case .redact:
            let (redacted, redactedHits) = redact(arguments)
            return .redact(args: redacted as? [String: Any] ?? arguments, hits: dedup(redactedHits))
        }
    }

    // MARK: - Recursion over arbitrary JSON-shaped values

    private static func collectHits(in value: Any) -> [String] {
        switch value {
        case let s as String:
            return SecretPatterns.hits(in: s)
        case let dict as [String: Any]:
            // Sort keys for deterministic hit ordering across runs.
            return dict.sorted { $0.key < $1.key }.flatMap { collectHits(in: $0.value) }
        case let array as [Any]:
            return array.flatMap { collectHits(in: $0) }
        default:
            return []
        }
    }

    /// Recursively redact string leaves, preserving the dict/array structure. Returns the
    /// rebuilt value and the patterns that fired.
    private static func redact(_ value: Any) -> (Any, [String]) {
        switch value {
        case let s as String:
            let r = SecretPatterns.redact(s)
            return (r.redacted, r.hits)
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            var hits: [String] = []
            for (key, val) in dict.sorted(by: { $0.key < $1.key }) {
                let (rv, h) = redact(val)
                out[key] = rv
                hits += h
            }
            return (out, hits)
        case let array as [Any]:
            var out: [Any] = []
            var hits: [String] = []
            for val in array {
                let (rv, h) = redact(val)
                out.append(rv)
                hits += h
            }
            return (out, hits)
        default:
            return (value, [])
        }
    }

    private static func dedup(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
