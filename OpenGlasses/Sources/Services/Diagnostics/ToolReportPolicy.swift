import Foundation

// MARK: - What a Field Assist tool was asked and answered (Plan NI)
//
// A support report used to show `rule_chain (completed)` and nothing else, so a tester whose every
// chain start was refused by the start gate could not tell (build 770). The three Field Assist
// tools a reviewer most needs to see now keep their arguments and what they returned, masked and
// bounded exactly like a web search's evidence.
//
// The code books are licensed, and reports get pasted into outside AI tools. So a lookup's returned
// text is shown only when it is the app's own words (a refusal, a question back, a miss), or in the
// version the tool itself wrote for a report, with the book's cells, notes and passages replaced by
// a count (owner decision D1, 2026-11-27). A lookup that doesn't say what it returned is shown by
// size only: the policy fails closed.

extension TurnTimeline {

    /// A Field Assist tool call's arguments and returned text, as a support report shows them.
    /// Kept only in the on-device support trace, like `SearchEvidence`; a private conversation's
    /// trace drops it (`TurnTrace.withoutText()`).
    struct ToolEvidence: Equatable, Codable {
        static let argumentLimit = SearchEvidence.queryLimit

        struct Argument: Equatable, Codable {
            let name: String
            let value: String
            let truncated: Bool
        }

        let arguments: [Argument]
        /// The returned text as the report shows it: the text itself, or the tool's own report
        /// version of it. Empty when it is not shown at all.
        let returned: String
        let returnedTruncated: Bool
        /// Characters of the book's own text (cells, notes, passages) left out of `returned`.
        /// Nil when nothing was left out.
        var bookTextLeftOut: Int? = nil
        /// The returned text was not shown, only its size: a lookup that did not say what it
        /// returned. Nil when it was shown.
        var notShownCharacters: Int? = nil

        init(arguments: [(name: String, value: String)], returned: ToolReportPolicy.Returned,
             remainingResultCharacters: Int = SearchEvidence.turnResultLimit, secrets: [String] = []) {
            // Scrub before cutting, as a search does: a cut through a token must not leave half a
            // secret.
            self.arguments = arguments.map { argument in
                let safe = DiagnosticsRedactor.redact(argument.value, extraSecrets: secrets).redacted
                return Argument(name: argument.name, value: String(safe.prefix(Self.argumentLimit)),
                                truncated: safe.count > Self.argumentLimit)
            }
            let shown: String
            switch returned {
            case .asReturned(let text):
                shown = text
            case .bookTextLeftOut(let text, let leftOut):
                shown = text
                bookTextLeftOut = leftOut
            case .sizeOnly(let characters):
                shown = ""
                notShownCharacters = characters
            }
            let safe = DiagnosticsRedactor.redact(shown, extraSecrets: secrets).redacted
            let limit = max(0, min(SearchEvidence.resultLimit, remainingResultCharacters))
            self.returned = String(safe.prefix(limit))
            returnedTruncated = safe.count > limit
        }
    }
}

/// Which tools keep their arguments and returned text in the support trace, which arguments, and
/// how much of a lookup's returned text a report may show (Plan NI). Pure.
enum ToolReportPolicy {

    /// The tools that keep evidence, each with the arguments it keeps, in schema order. Every other
    /// tool stays name and outcome (D5): a tool joins by being named here, never by default.
    static let argumentNames: [String: [String]] = [
        "rule_chain": ["action", "chain", "step", "value"],
        "table_lookup": ["table", "row", "column", "document"],
        "manual_lookup": ["query", "document", "use_camera", "queries"],
    ]

    /// The tools whose returned text can carry a licensed book's own words.
    static let answersFromTheBook: Set<String> = ["table_lookup", "manual_lookup"]

    static func keepsEvidence(_ tool: String) -> Bool { argumentNames[tool] != nil }

    /// How a report shows a call's returned text.
    enum Returned: Equatable {
        /// In full: the app's own words.
        case asReturned(String)
        /// The tool's report version, with `leftOut` characters of the book's text replaced.
        case bookTextLeftOut(String, leftOut: Int)
        /// Not shown: only its size.
        case sizeOnly(Int)
    }

    /// The kept arguments of a call, by name in the policy's order, rendered as text. A missing or
    /// empty argument is skipped. `queries` (manual_lookup's rewrites) is flattened to
    /// `language: query` items.
    static func arguments(of tool: String, in args: [String: Any]) -> [(name: String, value: String)] {
        (argumentNames[tool] ?? []).compactMap { name in
            guard let raw = args[name], let text = text(of: raw), !text.isEmpty else { return nil }
            return (name, text)
        }
    }

    /// What the report shows of a call's returned text. `report` is what the tool recorded for
    /// this call with `ToolReportText.record(_:)`, if anything.
    static func returned(tool: String, outcome: String, result: String,
                         report: ToolReportText.Entry?) -> Returned {
        // Not a lookup, or a call that never reached the book: the dispatcher's refusal or failure
        // reason is the app's own words.
        guard answersFromTheBook.contains(tool), outcome == "completed" else { return .asReturned(result) }
        switch report {
        case .asReturned?: return .asReturned(result)
        case .bookTextLeftOut(let text, let leftOut)?: return .bookTextLeftOut(text, leftOut: leftOut)
        case .sizeOnly?, nil: return .sizeOnly(result.count)
        }
    }

    private static func text(of value: Any) -> String? {
        if let string = value as? String {
            return string.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        }
        if let items = value as? [[String: Any]] {
            let parts = items.compactMap { item -> String? in
                guard let query = (item["query"] as? String).flatMap(text(of:)), !query.isEmpty else { return nil }
                let language = (item["language"] as? String).flatMap(text(of:)) ?? ""
                return language.isEmpty ? query : "\(language): \(query)"
            }
            return parts.joined(separator: "; ")
        }
        if let items = value as? [Any] {
            return items.compactMap(text(of:)).joined(separator: "; ")
        }
        return nil
    }
}

/// What a tool says the support report should show of the result it is returning (Plan NI): its
/// own words as they are, or a version with the book's text left out. A task-local slot, like
/// `ActionCompletionReport`: the dispatcher opens a collector around one native call, and a tool
/// inside it records. Outside a collector, recording does nothing.
@MainActor
enum ToolReportText {

    enum Entry: Equatable {
        /// The result is the app's own words: show it as it is.
        case asReturned
        /// The result holds the book's text: show this instead, which has `leftOut` characters of
        /// it replaced.
        case bookTextLeftOut(String, leftOut: Int)
        /// The result holds the book's text and the tool could not write a version without it:
        /// show its size only.
        case sizeOnly
    }

    final class Slot {
        fileprivate(set) var entry: Entry?
    }

    @TaskLocal static var slot: Slot?

    /// A tool says what the report should show of the result it is about to return.
    static func record(_ entry: Entry) {
        slot?.entry = entry
    }

    /// The record of a tool's own words, made after its work: it never replaces a version with the
    /// book's text left out that the work recorded.
    static func recordIfNone(_ entry: Entry) {
        guard let slot, slot.entry == nil else { return }
        slot.entry = entry
    }

    /// The dispatcher's half: run one call and read what its tool recorded, if anything.
    static func collect<T>(_ work: () async throws -> T) async rethrows -> (T, Entry?) {
        let collector = Slot()
        let value = try await $slot.withValue(collector) { try await work() }
        return (value, collector.entry)
    }
}
