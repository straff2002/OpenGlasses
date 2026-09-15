import Foundation

/// Maps a custom endpoint's status/result JSON onto `AgentRunResult` (Plan FE P0), and bounds
/// everything it takes.
///
/// Two rules do the work here:
///
///  * **Absent is unknown.** A path the user did not map, or one the response does not answer,
///    leaves the field out of `reported`. Only what came back is claimed; the summarizer says so.
///  * **The payload is untrusted.** The far end is a URL the user pointed us at, and its text ends
///    up in a spoken line, so every string is stripped of control characters and capped, arrays are
///    capped, and the PR URL has to parse as http(s) before it is believed.
enum AgentResultMapping {

    /// Per-item cap for a path, a command, or an error message.
    static let maxItemLength = 200
    /// Cap for the agent's closing words. The spoken line is capped again at
    /// `AgentSummarizer.maxLength`; this bounds what we carry around and log about.
    static let maxFinalTextLength = 600
    /// Cap on list length. Only the *count* is ever spoken, so an endpoint claiming 100 000 changed
    /// files would otherwise both allocate freely and narrate a number nobody can act on.
    static let maxItems = 100
    /// Cap on a raw status label echoed back to the user.
    static let maxStatusLabelLength = 40

    /// Build the result from one status response, using the config's mapped paths.
    static func result(from json: [String: Any], config: CustomHarnessConfig) -> AgentRunResult {
        var result = AgentRunResult()

        if let created = list(at: config.filesCreatedPath, in: json) {
            result.filesCreated = created
            result.reported.insert(.filesCreated)
        }
        if let modified = list(at: config.filesModifiedPath, in: json) {
            result.filesModified = modified
            result.reported.insert(.filesModified)
        }
        if let commands = list(at: config.commandsRunPath, in: json) {
            result.commandsRun = commands
            result.reported.insert(.commandsRun)
        }
        if let pushed = JSONPath.bool(at: config.pushedPath, in: json) {
            result.pushed = pushed
            result.reported.insert(.pushed)
        }
        if let raw = JSONPath.string(at: config.prURLPath, in: json) {
            // A reported-but-unusable URL is still a report: we know it opened something, we just
            // won't repeat a link we can't vouch for.
            result.reported.insert(.prURL)
            result.prURL = webURL(raw)
        }
        if let text = sanitized(JSONPath.string(at: config.finalTextPath, in: json),
                                limit: maxFinalTextLength) {
            result.finalText = text
            result.reported.insert(.finalText)
        }
        if let message = sanitized(JSONPath.string(at: config.errorPath, in: json),
                                   limit: maxItemLength) {
            result.error = message
            result.reported.insert(.error)
        }
        return result
    }

    // MARK: - Questions (Plan FE P1)

    /// Cap on a question prompt. It is spoken, and it is endpoint-authored text.
    static let maxPromptLength = 300

    /// What one status response said about the question a run is waiting on. Every field is
    /// optional: an endpoint that maps none of them still pauses, it just says nothing about why.
    struct QuestionPayload: Equatable {
        var id: String?
        var revision: Int?
        var kind: String?
        var prompt: String?

        /// True when the endpoint named the question itself, so the identity is the endpoint's
        /// rather than one derived from arrival order.
        var hasExplicitID: Bool { !(id ?? "").isEmpty }
    }

    /// Read the pending-question fields, with the same hygiene as every other mapped string.
    static func question(from json: [String: Any], config: CustomHarnessConfig) -> QuestionPayload {
        QuestionPayload(
            id: sanitized(JSONPath.string(at: config.questionIDPath, in: json), limit: maxItemLength),
            revision: revision(JSONPath.string(at: config.questionRevisionPath, in: json)),
            kind: sanitized(JSONPath.string(at: config.questionKindPath, in: json),
                            limit: maxStatusLabelLength),
            prompt: sanitized(JSONPath.string(at: config.questionPromptPath, in: json),
                              limit: maxPromptLength))
    }

    /// A revision number, or `nil`. A revision we cannot read is no revision at all — inventing one
    /// would make a re-ask look like a repeat, or the reverse.
    static func revision(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }

    /// A bounded list of bounded strings, or `nil` when the path is unmapped/absent.
    static func list(at path: String, in json: [String: Any]) -> [String]? {
        guard let raw = JSONPath.strings(at: path, in: json) else { return nil }
        return raw.prefix(maxItems).compactMap { sanitized($0, limit: maxItemLength) }
    }

    /// Strip control characters, collapse whitespace, trim, and cap. `nil` when nothing is left —
    /// an endpoint that reports an empty string has told us nothing.
    static func sanitized(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        var out = ""
        out.reserveCapacity(min(raw.count, limit))
        for scalar in raw.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) || scalar == " " || scalar == "\t" {
                if !out.hasSuffix(" ") { out.append(" ") }
            } else if CharacterSet.controlCharacters.contains(scalar) {
                continue    // drop: nothing good reaches TTS or a log line from here
            } else {
                out.unicodeScalars.append(scalar)
            }
            if out.count >= limit { break }
        }
        let trimmed = String(out.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A raw status label, safe to echo back to the user.
    static func statusLabel(_ raw: String?) -> String {
        sanitized(raw, limit: maxStatusLabelLength) ?? ""
    }

    /// The URL only if it parses as http(s) with a host. Anything else — `javascript:`, a bare
    /// word, a 4 KB blob — is dropped rather than spoken or offered as a link.
    static func webURL(_ raw: String?) -> String? {
        guard let trimmed = sanitized(raw, limit: maxItemLength),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }
}
