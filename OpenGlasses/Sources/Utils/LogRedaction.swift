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
/// rather than filtered. New logging goes there. The remaining callers here are the OpenClaw
/// gateway connect path (`OpenClawBridge`, `OpenClawEventClient`), which still log URLs and
/// handshake bodies and are queued for migration with the rest of the authentication/networking
/// tier; `Scripts/check-privacy-logging.sh` counts them.
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
