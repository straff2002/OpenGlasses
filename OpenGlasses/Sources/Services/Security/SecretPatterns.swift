import Foundation

/// Shared, deterministic pattern set for spotting secrets and PII/PHI in free text.
///
/// Used by both the outbound `EgressScreen` (don't hand a third-party MCP server your API
/// keys or health-vault text) and the discovery-time `ToolDefinitionScanner`. Pure and
/// regex-only — no LLM, no I/O — so it's fully unit-testable and runs in well under a
/// millisecond on a tool call's worth of arguments.
///
/// Patterns err toward **low false positives** on ordinary prose: secret patterns require a
/// distinctive prefix + a run of token characters, and PII patterns are shaped (an email has
/// an `@` and a TLD; an IRD id is dash-grouped digits). Misses are acceptable for v1 —
/// taint-tracking from `health_vault`/`notes_vault` is the planned fast-follow if real
/// false-negatives show up. See [[PromptInjectionPolicy]] for the inbound mirror.
enum SecretPatterns {

    enum Category: String, Equatable {
        case secret   // credentials / tokens — never leave the device in plaintext
        case pii      // personal / health-adjacent identifiers — redacted by default
    }

    struct Pattern {
        let name: String          // stable label, surfaced as "what was masked"
        let category: Category
        let regex: NSRegularExpression
    }

    /// The placeholder substituted for a matched secret/PII span during redaction.
    static let redactionPlaceholder = "‹redacted›"

    /// All patterns, secrets first. Compiled once.
    static let all: [Pattern] = [
        // MARK: Secrets
        pattern("openai_key", .secret, #"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}"#),
        pattern("github_token", .secret, #"gh[pousr]_[A-Za-z0-9]{20,}"#),
        pattern("slack_token", .secret, #"xox[baprs]-[A-Za-z0-9-]{10,}"#),
        pattern("google_api_key", .secret, #"AIza[0-9A-Za-z_-]{35}"#),
        pattern("aws_access_key_id", .secret, #"\bAKIA[0-9A-Z]{16}\b"#),
        pattern("jwt", .secret, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        pattern("bearer_token", .secret, #"(?i)bearer\s+[A-Za-z0-9._-]{16,}"#),
        pattern("private_key_block", .secret, #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#),

        // MARK: PII / PHI
        pattern("email", .pii, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        // NZ IRD number — 8 or 9 digits, conventionally dash-grouped (xx-xxx-xxx / xxx-xxx-xxx).
        pattern("nz_ird", .pii, #"\b\d{2,3}-\d{3}-\d{3}\b"#),
    ]

    /// Names of the patterns that match anywhere in `text` (deduplicated, in `all` order).
    static func hits(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return all.compactMap { pattern in
            pattern.regex.firstMatch(in: text, options: [], range: range) != nil ? pattern.name : nil
        }
    }

    /// Whether `text` contains any secret or PII match.
    static func containsSensitive(_ text: String) -> Bool {
        !hits(in: text).isEmpty
    }

    /// Replace every secret/PII match in `text` with `redactionPlaceholder`, returning the
    /// masked string and the names of the patterns that fired (in `all` order). Non-matching
    /// text is preserved verbatim, so redaction never reshapes the surrounding string.
    static func redact(_ text: String, placeholder: String = redactionPlaceholder) -> (redacted: String, hits: [String]) {
        guard !text.isEmpty else { return (text, []) }
        var result = text
        var fired: [String] = []
        for pattern in all {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            guard pattern.regex.firstMatch(in: result, options: [], range: range) != nil else { continue }
            fired.append(pattern.name)
            result = pattern.regex.stringByReplacingMatches(
                in: result, options: [],
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: placeholder)
            )
        }
        return (result, fired)
    }

    // MARK: - Construction

    private static func pattern(_ name: String, _ category: Category, _ raw: String) -> Pattern {
        // Patterns are compile-time constants authored in this file; a bad one is a programmer
        // error we want to surface loudly in development, not swallow.
        guard let regex = try? NSRegularExpression(pattern: raw) else {
            fatalError("SecretPatterns: invalid regex for \(name): \(raw)")
        }
        return Pattern(name: name, category: category, regex: regex)
    }
}
