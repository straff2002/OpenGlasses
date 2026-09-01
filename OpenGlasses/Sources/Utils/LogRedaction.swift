import Foundation

/// Last-line defence for **user-initiated diagnostic exports** — not a licence to log content.
///
/// Read this before reaching for it. It masks exactly two token shapes (`token=` in a query
/// string, `"token":` in JSON) in an otherwise arbitrary string. That is useful as a final pass
/// over a bundle the user has chosen to send us, where something unexpected may have slipped in.
/// It is **not** a way to make a content-bearing log statement acceptable:
///
/// - most sensitive material is not a token — a transcript, a tool argument, a home entity, an
///   OCR result and a URL path all pass through untouched;
/// - masking a credential inside a string does nothing about the rest of the string;
/// - truncating a prefix bounds volume, not sensitivity.
///
/// The production logging API is `PrivacyLog`, whose types make content structurally impossible
/// rather than filtered. New logging goes there. **Nothing in production Sources calls this
/// today**: the four gateway connect-path callers (`OpenClawBridge`, `OpenClawEventClient`) that
/// pushed URLs and handshake bodies through it were migrated to typed gateway events, which is
/// the outcome this file's warning was pointing at. It stays for the P3 diagnostics export.
enum LogRedaction {
    static let mask = "***"

    /// Mask the value of any `token=…` query parameter *and* any `"token": "…"` JSON field.
    static func redact(_ text: String) -> String {
        redactJSONToken(redactQueryToken(text))
    }

    /// `…?token=SECRET&x=1` → `…?token=***&x=1` (case-insensitive on the key).
    static func redactQueryToken(_ text: String) -> String {
        replace(in: text, pattern: #"(?i)([?&]token=)[^&\s"']+"#, with: "$1\(mask)")
    }

    /// `"token":"SECRET"` (any surrounding whitespace) → `"token":"***"`.
    static func redactJSONToken(_ text: String) -> String {
        replace(in: text, pattern: #"("token"\s*:\s*")[^"]*(")"#, with: "$1\(mask)$2")
    }

    private static func replace(in text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
