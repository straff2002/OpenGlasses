import Foundation

/// The single place that decides what an on-device model's raw output *is* — and what, if
/// anything, of it may be spoken, stored or acted on (Plan FC P1).
///
/// ### Why one policy rather than a regex per boundary
/// The local turn has five places where model text turns into something durable: the streaming
/// preview, the corrective re-generation, the tool-result re-generation, the web re-ask, and the
/// two `conversationHistory` insertions. Each of them used to strip protocol markup with its own
/// copy of `<tool_call>.*?</tool_call>`, which only ever matched a *complete* frame. A frame the
/// model never closed (it hit the token ceiling mid-JSON), a stray `</tool_call>`, or a bare call
/// object with no tags at all therefore survived every one of them and could be spoken by TTS and
/// written into history as the assistant's answer. Classifying once, here, is what makes "never
/// speak protocol" a property of the turn instead of a property of five regexes.
///
/// ### What it deliberately does not do
/// It never *repairs* a call. (Gemma 4's own call syntax, `name{key:<|"|>value<|"|>}`, is a second
/// grammar read in full or not at all — `gemmaCall` — not a repair; a Python-style
/// `name(key=value)` standing on its own line is a third — `pythonCall`.) A frame whose JSON does not parse, or whose object lacks a `name` or
/// an `arguments` object, is reported as malformed and dropped — guessing a tool or an argument out
/// of broken text would be inventing an action the model did not successfully ask for. And it never
/// judges a call by its name: unknown or disallowed tools keep going through the router's existing
/// authorization, which this type has no part in.
///
/// ### What it must never reject
/// Ordinary English that merely *mentions* tools or JSON. "Face the window", "The web_search tool
/// accepts a query", a sentence quoting `{"name": "x"}`, and non-Latin text all classify as prose
/// and pass through byte-identical (modulo trimming). That rules out prefix/substring bans: the
/// only things treated as protocol are a real tag or a JSON object that is *structurally* a call
/// and stands alone on its own line.
enum LocalOutputPolicy {

    static let openTag = "<tool_call>"
    static let closeTag = "</tool_call>"

    /// A call the model successfully asked for. Arguments are handed on untouched — the router
    /// owns what they mean.
    struct Invocation {
        let name: String
        let arguments: [String: Any]
    }

    /// What one generation turned out to be.
    ///
    /// `proseWithProtocol` is the narrow "mixed, but nothing callable and nothing truncated" case —
    /// in practice an empty frame (`<tool_call></tool_call>`). Ordinary mixed output (prose plus a
    /// usable or a broken call) is reported as `toolCall` / `malformedCall` with the surviving
    /// prose in `text`, because the caller's decision there depends on the call, not on the prose.
    enum Kind: String, Equatable {
        /// No protocol text anywhere.
        case prose
        /// Protocol fragments were removed; nothing callable, nothing truncated.
        case proseWithProtocol
        /// At least one usable call (`name` + `arguments`). Prose around it survives in `text`.
        case toolCall
        /// Protocol was present but no usable call could be formed from it — unparseable JSON,
        /// missing keys, or a bare (untagged) call object, which is not the protocol this app
        /// offers and is therefore never executed.
        case malformedCall
        /// A frame the model never closed, or a close tag whose opening never arrived.
        case incompleteFrame
    }

    struct Classification {
        let kind: Kind
        /// Speakable and persistable text: every protocol fragment removed, a transcript-style
        /// speaker label stripped, whitespace tidied. May be empty — that is the caller's cue that
        /// there is no answer left to say.
        let text: String
        /// Set only for `.toolCall`: the call a single-call reader runs.
        let invocation: Invocation?
        /// Every usable call, in the order the output gave them (Plan MQ P3): `LocalToolLoop` runs
        /// them all, since Gemma 4 E2B asks for a two-step turn's both calls in one reply. Empty
        /// unless `.toolCall`.
        var invocations: [Invocation] = []

        /// True when any protocol fragment was found and removed. The reason a caller can tell
        /// "the model said nothing" (an empty completion, still an error) apart from "the model
        /// said only broken protocol" (an honest miss).
        var carriesProtocol: Bool { kind != .prose }
    }

    // MARK: - Classification

    static func classify(_ raw: String) -> Classification {
        var removals: [Range<String.Index>] = []
        var invocation: Invocation?
        var found: [(at: String.Index, call: Invocation)] = []
        var sawMalformed = false
        var sawIncomplete = false
        var sawEmptyFrame = false

        // Pass 1 — tagged frames, in order. A frame with no close tag runs to the end of the
        // output: the model was cut off mid-protocol and everything after the open tag is protocol,
        // not speech.
        // Pass 0 — Gemma 4's own call syntax behind an opener that isn't ours (`<tool_call:name{…}>`,
        // `<|tool_call>call:name{…}<tool_call|>`): taken only when its body reads completely
        // (`gemmaCall`); otherwise the rest of its line is protocol, removed and never run.
        for opener in gemmaOpeners {
            var scan = raw.startIndex
            while let open = raw.range(of: opener, range: scan..<raw.endIndex) {
                if let (call, end) = gemmaCall(in: raw, from: open.upperBound) {
                    removals.append(open.lowerBound..<end)
                    if invocation == nil { invocation = call }
                    found.append((open.lowerBound, call))
                    scan = end
                } else {
                    let lineEnd = raw[open.upperBound...].firstIndex(where: \.isNewline) ?? raw.endIndex
                    removals.append(open.lowerBound..<lineEnd)
                    sawMalformed = true
                    scan = lineEnd
                }
            }
        }

        var cursor = raw.startIndex
        while let open = raw.range(of: openTag, range: cursor..<raw.endIndex) {
            guard let close = raw.range(of: closeTag, range: open.upperBound..<raw.endIndex) else {
                removals.append(open.lowerBound..<raw.endIndex)
                // Gemma 4 leaves its own frame unclosed (`<tool_call>name{…}`): a body that reads
                // whole is still its call.
                let tail = String(raw[open.upperBound...])
                if invocation == nil,
                   let call = gemmaCall(wholly: tail)
                    ?? pythonCall(tail.trimmingCharacters(in: .whitespacesAndNewlines))?.call {
                    invocation = call
                    found.append((open.lowerBound, call))
                } else {
                    sawIncomplete = true
                }
                cursor = raw.endIndex
                break
            }
            removals.append(open.lowerBound..<close.upperBound)
            let payload = raw[open.upperBound..<close.lowerBound]
            if let call = parseCallObject(String(payload)) ?? gemmaCall(wholly: String(payload))
                ?? pythonCall(String(payload).trimmingCharacters(in: .whitespacesAndNewlines))?.call {
                // First usable call wins for a single-call reader. A second frame in the same output
                // is still removed from the text; only `invocations` readers run it.
                if invocation == nil { invocation = call }
                found.append((open.lowerBound, call))
            } else if payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawEmptyFrame = true
            } else {
                sawMalformed = true
            }
            cursor = close.upperBound
        }

        // Pass 2 — what is left between the frames: Python-style call lines, bare call objects and
        // orphan close tags.
        for gap in gaps(in: raw, excluding: removals) {
            let lines = pythonCallLines(in: raw, gap: gap)
            removals += lines.removals
            for (at, call) in lines.reads {
                if let call {
                    if invocation == nil { invocation = call }
                    found.append((at, call))
                } else {
                    sawMalformed = true
                }
            }
            for range in bareCallRanges(in: raw, gap: gap) {
                removals.append(range)
                // A bare object is protocol-shaped output, not the protocol: it is removed so it is
                // never spoken, and reported as malformed so it is never executed.
                sawMalformed = true
            }
            var scan = gap.lowerBound
            while let orphan = raw.range(of: closeTag, range: scan..<gap.upperBound) {
                removals.append(orphan)
                sawIncomplete = true
                scan = orphan.upperBound
            }
        }

        let kind: Kind
        if invocation != nil {
            kind = .toolCall
        } else if sawMalformed {
            kind = .malformedCall
        } else if sawIncomplete {
            kind = .incompleteFrame
        } else if sawEmptyFrame {
            kind = .proseWithProtocol
        } else {
            kind = .prose
        }

        return Classification(kind: kind,
                              text: tidied(raw, removing: removals),
                              invocation: invocation,
                              invocations: found.sorted { $0.at < $1.at }.map(\.call))
    }

    /// The speakable text of a completion, with no classification. Convenience for boundaries that
    /// only need the cleanup (history sanitation).
    static func speakableText(_ raw: String) -> String { classify(raw).text }

    // MARK: - Call parsing

    /// A frame payload that is a well-formed call: a JSON object with a non-empty `name` string and
    /// an `arguments` object. Anything else — trailing prose, a truncated object, `{"tool": …}` —
    /// is not a call, and is never coerced into one.
    static func parseCallObject(_ payload: String) -> Invocation? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let arguments = object["arguments"] as? [String: Any] else { return nil }
        return Invocation(name: name, arguments: arguments)
    }

    // MARK: - Gemma 4's call syntax

    /// Openers Gemma 4 E2B was seen writing in text, on the phone, after the "I'll look that up"
    /// correction: half its native frame (`<|tool_call>call:…<tool_call|>`), half ours
    /// (`<tool_call>`). Our own `<tool_call>` is pass 1's; its payload may be Gemma's too.
    static let gemmaOpeners = ["<tool_call:", "<|tool_call>"]

    /// Gemma 4's string delimiter inside a call body.
    static let gemmaQuote = "<|\"|>"

    /// A call in Gemma 4's own syntax starting at `start`: an optional `call:`, a tool name, then
    /// a `{key:value,…}` body (strings between `<|"|>` marks, numbers, true/false) or `()`. Taken
    /// only when the body closes and every pair reads; the closing debris on the same line (`}`,
    /// `>`, `<tool_call|>`, `</tool_call>`) is part of the range. Not a repair: a second, fully
    /// specified grammar, and nothing that doesn't read under it becomes a call (Plan MQ P3).
    static func gemmaCall(in raw: String, from start: String.Index) -> (Invocation, String.Index)? {
        var index = raw[start...].firstIndex { !$0.isWhitespace } ?? raw.endIndex
        if raw[index...].hasPrefix("call:") { index = raw.index(index, offsetBy: 5) }
        let nameEnd = raw[index...].firstIndex { !($0.isLetter || $0.isNumber || $0 == "_") } ?? raw.endIndex
        let name = String(raw[index..<nameEnd])
        guard let first = name.first, first.isLetter || first == "_", nameEnd < raw.endIndex else { return nil }
        var arguments: [String: Any] = [:]
        var cursor = nameEnd
        if raw[cursor...].hasPrefix("()") {
            cursor = raw.index(cursor, offsetBy: 2)
        } else {
            guard raw[cursor] == "{" else { return nil }
            cursor = raw.index(after: cursor)
            while true {
                cursor = raw[cursor...].firstIndex { !$0.isWhitespace } ?? raw.endIndex
                guard cursor < raw.endIndex else { return nil }
                if raw[cursor] == "}" { cursor = raw.index(after: cursor); break }
                guard let colon = raw[cursor...].firstIndex(of: ":") else { return nil }
                let key = raw[cursor..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
                cursor = raw[raw.index(after: colon)...].firstIndex { !$0.isWhitespace } ?? raw.endIndex
                if raw[cursor...].hasPrefix(gemmaQuote) {
                    let valueStart = raw.index(cursor, offsetBy: gemmaQuote.count)
                    guard let close = raw.range(of: gemmaQuote, range: valueStart..<raw.endIndex) else { return nil }
                    arguments[key] = String(raw[valueStart..<close.lowerBound])
                    cursor = close.upperBound
                } else {
                    let valueEnd = raw[cursor...].firstIndex { $0 == "," || $0 == "}" || $0.isNewline } ?? raw.endIndex
                    let token = raw[cursor..<valueEnd].trimmingCharacters(in: .whitespaces)
                    if token == "true" || token == "false" {
                        arguments[key] = token == "true"
                    } else if let number = Double(token), token.first.map({ $0.isNumber || $0 == "-" }) == true {
                        arguments[key] = token.contains(".") ? number as Any : (Int(exactly: number).map { $0 as Any } ?? number)
                    } else {
                        return nil
                    }
                    cursor = valueEnd
                }
                cursor = raw[cursor...].firstIndex { !$0.isWhitespace } ?? raw.endIndex
                guard cursor < raw.endIndex else { return nil }
                if raw[cursor] == "," { cursor = raw.index(after: cursor); continue }
                guard raw[cursor] == "}" else { return nil }
                cursor = raw.index(after: cursor)
                break
            }
        }
        // The frame's closing debris, on the same line.
        while cursor < raw.endIndex {
            let rest = raw[cursor...]
            if let tag = ["<tool_call|>", closeTag].first(where: { rest.hasPrefix($0) }) {
                cursor = raw.index(cursor, offsetBy: tag.count)
            } else if rest.first == "}" || rest.first == ">" || rest.first == " " || rest.first == "\t" {
                cursor = raw.index(after: cursor)
            } else {
                break
            }
        }
        return (Invocation(name: name, arguments: arguments), cursor)
    }

    /// A whole frame payload in Gemma 4's syntax, with nothing but closing debris and whitespace
    /// after it.
    static func gemmaCall(wholly payload: String) -> Invocation? {
        guard let (call, end) = gemmaCall(in: payload, from: payload.startIndex),
              payload[end...].allSatisfy({ $0.isWhitespace }) else { return nil }
        return call
    }

    // MARK: - Python-style calls

    /// How a call-shaped line read: a call, or a shape that is a call's but not one this grammar
    /// reads (`nil` — removed and never run, like a frame whose body does not read).
    struct PythonRead {
        let call: Invocation?
    }

    /// Fence languages a call block may carry. Any other fence is code someone is being shown.
    static let pythonFenceLanguages: Set<String> = ["", "python", "py", "tool_code"]

    /// A Python-style call, `name(key=value, …)`, the whole of `text`: optionally after `call:` or
    /// inside one code span. On the phone Gemma 4 E2B once answered with only
    /// `reading(action="record_reading", quantity="flame signal", unit="µA", value="2.9")`, and
    /// nothing was logged. Like `gemmaCall`, a third grammar read in full or not at all, not a
    /// repair (Plan MQ P3): keyword arguments only, each a quoted string (`\"`/`\'` escapes), a
    /// number (typed as Gemma's are), `True`/`False`, or `None` (the key dropped). Positional
    /// arguments, nested calls, expressions, lists and dicts are a call's shape that does not
    /// read: `PythonRead(call: nil)`, never run. Nil when `text` is not call-shaped at all — a
    /// lowercase tool-like name right against `(`, closed by the last character — so a sentence
    /// is never read. The policy is not told which tools were offered, so the name is held only
    /// to that shape; its callers keep it to a whole line of the output or a frame's whole payload.
    static func pythonCall(_ text: String) -> PythonRead? {
        var text = Substring(text)
        if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`"), !text.hasPrefix("``") {
            text = text.dropFirst().dropLast()
        }
        if text.hasPrefix("call:") { text = text.dropFirst(5).drop { $0 == " " } }
        let name = text.prefix { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_") }
        guard let first = name.first, first.isLetter,
              text.dropFirst(name.count).first == "(", text.last == ")", text.count > name.count + 1 else { return nil }
        let body = Array(text.dropFirst(name.count + 1).dropLast())
        return PythonRead(call: pythonArguments(body).map { Invocation(name: String(name), arguments: $0) })
    }

    /// The keyword arguments between a Python-style call's parentheses, or nil when any of it
    /// does not read.
    private static func pythonArguments(_ body: [Character]) -> [String: Any]? {
        var arguments: [String: Any] = [:]
        var keys = Set<String>()
        var index = 0
        func skipSpaces() { while index < body.count, body[index] == " " || body[index] == "\t" { index += 1 } }
        skipSpaces()
        while index < body.count {
            let keyStart = index
            while index < body.count, body[index].isASCII,
                  body[index].isLetter || body[index].isNumber || body[index] == "_" { index += 1 }
            let key = String(body[keyStart..<index])
            guard let first = key.first, !first.isNumber, keys.insert(key).inserted else { return nil }
            skipSpaces()
            guard index < body.count, body[index] == "=" else { return nil }   // positional
            index += 1
            skipSpaces()
            guard index < body.count else { return nil }
            if body[index] == "\"" || body[index] == "'" {
                let quote = body[index]
                var value = ""
                var closed = false
                index += 1
                while index < body.count {
                    let character = body[index]
                    if character == "\\" {
                        guard index + 1 < body.count else { return nil }
                        let escaped = body[index + 1]
                        value.append(escaped == "n" ? "\n" : escaped == "t" ? "\t" : escaped)
                        index += 2
                    } else if character == quote {
                        closed = true
                        index += 1
                        break
                    } else {
                        value.append(character)
                        index += 1
                    }
                }
                guard closed else { return nil }
                arguments[key] = value
            } else {
                let tokenStart = index
                while index < body.count, body[index] != ",", body[index] != " ", body[index] != "\t" { index += 1 }
                let token = String(body[tokenStart..<index])
                switch token {
                case "True", "true": arguments[key] = true
                case "False", "false": arguments[key] = false
                case "None", "null": break
                default:
                    guard token.range(of: #"^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil,
                          let number = Double(token), number.isFinite else { return nil }
                    arguments[key] = token.contains(".") ? number as Any : (Int(exactly: number).map { $0 as Any } ?? number)
                }
            }
            skipSpaces()
            guard index < body.count else { break }
            guard body[index] == "," else { return nil }
            index += 1
            skipSpaces()
        }
        return arguments
    }

    /// The Python-style calls in a gap, each a whole line of the output: what to remove, and every
    /// call-shaped line read, in order (nil where it did not read). A fence (```` ``` ````,
    /// ```` ```python ````, ```` ```tool_code ````) is taken whole when every line in it is
    /// call-shaped, and otherwise left alone, lines and all — it is code being shown. A call
    /// inside a sentence never stands on its own line, so it is never read.
    private static func pythonCallLines(in raw: String, gap: Range<String.Index>)
        -> (removals: [Range<String.Index>], reads: [(at: String.Index, call: Invocation?)]) {
        // Each whole line of the gap, trimmed: one that starts and ends a line of the output.
        var lines: [(range: Range<String.Index>, text: String)] = []
        var lineStart = gap.lowerBound
        while lineStart < gap.upperBound {
            let lineEnd = raw[lineStart..<gap.upperBound].firstIndex(where: \.isNewline) ?? gap.upperBound
            if let first = raw[lineStart..<lineEnd].firstIndex(where: { !$0.isWhitespace }),
               startsLine(raw, at: first),
               lineEnd == raw.endIndex || raw[lineEnd].isNewline {
                let last = raw[first..<lineEnd].lastIndex { !$0.isWhitespace } ?? first
                lines.append((first..<raw.index(after: last), String(raw[first...last])))
            }
            lineStart = lineEnd < gap.upperBound ? raw.index(after: lineEnd) : gap.upperBound
        }

        var removals: [Range<String.Index>] = []
        var reads: [(at: String.Index, call: Invocation?)] = []
        var line = 0
        while line < lines.count {
            let text = lines[line].text
            if text.hasPrefix("```") {
                let language = text.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                if let close = lines[(line + 1)...].firstIndex(where: { $0.text == "```" }) {
                    let inner = lines[(line + 1)..<close]
                    let read = inner.compactMap { entry in pythonCall(entry.text).map { (entry.range.lowerBound, $0.call) } }
                    if pythonFenceLanguages.contains(language), !inner.isEmpty, read.count == inner.count {
                        removals.append(lines[line].range.lowerBound..<lines[close].range.upperBound)
                        reads += read
                    }
                    line = close + 1
                    continue
                }
            }
            // A call line that a stray close tag ends is still the call; the orphan scan takes the tag.
            let candidate = text.hasSuffix(closeTag)
                ? String(text.dropLast(closeTag.count)).trimmingCharacters(in: .whitespaces) : text
            if let read = pythonCall(candidate) {
                removals.append(lines[line].range)
                reads.append((lines[line].range.lowerBound, read.call))
            }
            line += 1
        }
        return (removals, reads)
    }

    // MARK: - Bare (untagged) call objects

    /// Ranges of gap text that are a bare call object.
    ///
    /// The three conditions together are what keeps ordinary prose safe. The object must
    ///  1. **start a line** (only whitespace between it and the previous newline), which excludes
    ///     every mid-sentence brace — `A call looks like {"name": "x"} in JSON.` is prose;
    ///  2. **parse as a call** (`name` + `arguments`), which excludes quoted fragments and code
    ///     samples that are not a complete call; and
    ///  3. **be alone on its line**, ignoring whitespace and a trailing close tag, which excludes a
    ///     sentence that happens to begin with a JSON example and then carries on explaining it.
    ///
    /// **Known limitation:** a *truncated* bare object (`{"name": "get_we`, no tags, no closing
    /// brace) cannot be told apart from a code fragment someone is asking about, so it is left as
    /// prose. Tagged truncation — the shape a cut-off generation actually produces — is caught by
    /// pass 1.
    private static func bareCallRanges(in raw: String, gap: Range<String.Index>) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var index = gap.lowerBound
        while index < gap.upperBound {
            guard raw[index] == "{", startsLine(raw, at: index) else {
                index = raw.index(after: index)
                continue
            }
            guard let end = balancedObjectEnd(raw, from: index, limit: gap.upperBound) else {
                index = raw.index(after: index)
                continue
            }
            let objectRange = index..<raw.index(after: end)
            guard parseCallObject(String(raw[objectRange])) != nil,
                  lineRemainderIsProtocolOnly(raw, from: objectRange.upperBound, limit: gap.upperBound) else {
                index = objectRange.upperBound
                continue
            }
            found.append(objectRange)
            index = objectRange.upperBound
        }
        return found
    }

    /// True when only whitespace separates `index` from the start of its line (or from the start of
    /// the output).
    private static func startsLine(_ raw: String, at index: String.Index) -> Bool {
        var cursor = index
        while cursor > raw.startIndex {
            cursor = raw.index(before: cursor)
            let character = raw[cursor]
            if character == "\n" || character == "\r" { return true }
            if !character.isWhitespace { return false }
        }
        return true
    }

    /// End index (inclusive) of the JSON object starting at `start`, or nil when it never closes
    /// inside `limit`. Brace counting is string-aware so a `}` inside a value cannot close it.
    private static func balancedObjectEnd(_ raw: String,
                                          from start: String.Index,
                                          limit: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < limit {
            let character = raw[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }

    /// True when the rest of the object's line is whitespace, or whitespace plus a close tag — the
    /// shape of an output that *is* a call rather than one that mentions one.
    private static func lineRemainderIsProtocolOnly(_ raw: String,
                                                    from index: String.Index,
                                                    limit: String.Index) -> Bool {
        var rest = ""
        var cursor = index
        while cursor < limit, raw[cursor] != "\n", raw[cursor] != "\r" {
            rest.append(raw[cursor])
            cursor = raw.index(after: cursor)
        }
        return rest
            .replacingOccurrences(of: closeTag, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    // MARK: - Text assembly

    /// The complement of `removals` inside `raw`, in order.
    private static func gaps(in raw: String,
                             excluding removals: [Range<String.Index>]) -> [Range<String.Index>] {
        let sorted = removals.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<String.Index>] = []
        var cursor = raw.startIndex
        for range in sorted {
            if cursor < range.lowerBound { result.append(cursor..<range.lowerBound) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < raw.endIndex { result.append(cursor..<raw.endIndex) }
        return result
    }

    /// The leading transcript-style speaker labels a small model might emit: the fixed ones, plus
    /// whatever the wearer named their assistant (Plan FE P6), regex-escaped so a name containing
    /// `.` or `(` is matched literally rather than compiled as a pattern.
    private static var speakerLabelPattern: String {
        // The product name, and the old one: conversation history from before the rename to
        // Avenkin (Plan FY P1 item 6) still carries it as a speaker label a model can echo.
        var labels = ["Avenkin", "OpenGlasses", "Assistant", "AI", "Model"]
        let name = Config.assistantName
        if !labels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            labels.append(NSRegularExpression.escapedPattern(for: name))
        }
        return #"^\s*("# + labels.joined(separator: "|") + #")\s*:\s*"#
    }

    /// Everything outside `removals`, with the seams that removal leaves behind tidied up and a
    /// transcript-style speaker label dropped.
    private static func tidied(_ raw: String, removing removals: [Range<String.Index>]) -> String {
        let kept = gaps(in: raw, excluding: removals).map { String(raw[$0]) }.joined()
        return kept
            // Removing a frame from the middle of a sentence leaves a double space; removing one
            // from its own line leaves a run of blank lines.
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            // A small model fed a merged (no-system-role) prompt can answer in transcript style —
            // "OpenGlasses: …" / "Assistant: …" — and TTS would speak the label. The wearer's own
            // assistant name is dropped the same way; it is escaped, never trusted as a pattern.
            .replacingOccurrences(of: speakerLabelPattern,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Streaming

/// Incremental protocol suppressor for the on-device *preview* channel (Plan FC P1).
///
/// The preview sink is a live UI bubble, so it sees chunks long before anything can be classified:
/// the detokenizer happily splits `<tool_call>` into `"<tool_"` + `"call>{"`, which is exactly the
/// text that must never appear. The filter holds back only what is genuinely ambiguous —
///
///  * the longest suffix that could still grow into `<tool_call>` / `</tool_call>` (at most ten
///    characters, the same trick `ThinkStreamFilter` uses for `<think>`), and
///  * a line-initial `{`, which could be the start of a bare call object, until the object closes
///    (suppressed if it is a call, released verbatim if it is not) or the buffer passes
///    `bareCandidateCeiling` characters (released — ordinary text is never held indefinitely).
///
/// Everything else is released as it arrives, so ordinary prose streams with at most a few
/// characters of lag. `flush()` at end of stream releases whatever was held back and was not
/// protocol after all.
final class LocalProtocolStreamFilter {

    /// How much line-initial `{…` is buffered before giving up and releasing it as ordinary text.
    /// Generous enough for a real call object, small enough that a reply that genuinely opens with
    /// a brace is not held for long.
    static let bareCandidateCeiling = 512

    private enum Mode {
        case text
        /// Inside an open `<tool_call>` frame: everything is protocol until the close tag.
        case frame
        /// Buffering a line-initial `{` that may turn out to be a bare call object.
        case bareCandidate
    }

    private var mode: Mode = .text
    private var pending = ""
    private var candidate = ""
    /// Swallow the whitespace a removed frame leaves behind, which may arrive in a later chunk.
    private var trimLeadingWhitespace = false
    /// True once the filter has emitted or is positioned mid-line, so `{` is no longer line-initial.
    private var atLineStart = true

    /// Feed one streamed chunk; returns the part that is safe to show *now*.
    func ingest(_ chunk: String) -> String {
        pending += chunk
        var visible = ""
        loop: while true {
            switch mode {
            case .frame:
                guard let close = pending.range(of: LocalOutputPolicy.closeTag) else {
                    // Hold only what could still complete the close tag; the rest is protocol.
                    let hold = Self.partialTagSuffixLength(of: pending, tag: LocalOutputPolicy.closeTag)
                    pending = String(pending.suffix(hold))
                    break loop
                }
                pending = String(pending[close.upperBound...])
                mode = .text
                trimLeadingWhitespace = true

            case .bareCandidate:
                candidate += pending
                pending = ""
                if let end = Self.balancedEnd(of: candidate) {
                    let object = String(candidate[...end])
                    let rest = String(candidate[candidate.index(after: end)...])
                    if LocalOutputPolicy.parseCallObject(object) != nil {
                        candidate = ""
                        pending = rest
                        mode = .text
                        trimLeadingWhitespace = true
                    } else {
                        visible += object
                        candidate = ""
                        pending = rest
                        mode = .text
                        atLineStart = object.hasSuffix("\n")
                    }
                    continue loop
                }
                if candidate.count > Self.bareCandidateCeiling {
                    visible += candidate
                    candidate = ""
                    mode = .text
                    atLineStart = false
                }
                break loop

            case .text:
                if trimLeadingWhitespace {
                    let dropped = pending.prefix(while: \.isWhitespace)
                    pending = String(pending.dropFirst(dropped.count))
                    if pending.isEmpty { break loop }   // more whitespace may follow next chunk
                    trimLeadingWhitespace = false
                    if dropped.contains("\n") { atLineStart = true }
                }
                guard let trigger = nextTrigger(in: pending) else {
                    let hold = max(
                        Self.partialTagSuffixLength(of: pending, tag: LocalOutputPolicy.openTag),
                        Self.partialTagSuffixLength(of: pending, tag: LocalOutputPolicy.closeTag))
                    let released = String(pending.dropLast(hold))
                    visible += released
                    if !released.isEmpty { atLineStart = Self.endsAtLineStart(released) }
                    pending = String(pending.suffix(hold))
                    break loop
                }
                let released = String(pending[pending.startIndex..<trigger.index])
                visible += released
                if !released.isEmpty { atLineStart = Self.endsAtLineStart(released) }
                switch trigger.kind {
                case .open:
                    pending = String(pending[trigger.index...].dropFirst(LocalOutputPolicy.openTag.count))
                    mode = .frame
                case .close:
                    // An orphan close tag: drop the token, keep streaming.
                    pending = String(pending[trigger.index...].dropFirst(LocalOutputPolicy.closeTag.count))
                case .brace:
                    candidate = String(pending[trigger.index...])
                    pending = ""
                    mode = .bareCandidate
                }
            }
        }
        return visible
    }

    /// End of stream: release anything held back that never became protocol.
    func flush() -> String {
        defer { pending = ""; candidate = "" }
        switch mode {
        case .frame:
            // A frame the model never closed is protocol to its last character.
            return ""
        case .bareCandidate:
            let buffered = candidate + pending
            if let end = Self.balancedEnd(of: buffered),
               LocalOutputPolicy.parseCallObject(String(buffered[...end])) != nil {
                return String(buffered[buffered.index(after: end)...])
            }
            // Never completed into a call object — it was ordinary text after all.
            return buffered
        case .text:
            return pending
        }
    }

    // MARK: - Scanning

    private enum TriggerKind { case open, close, brace }
    private struct Trigger { let index: String.Index; let kind: TriggerKind }

    /// The first thing in `text` that changes mode: an open tag, an orphan close tag, or a
    /// line-initial `{`.
    private func nextTrigger(in text: String) -> Trigger? {
        var candidates: [Trigger] = []
        if let open = text.range(of: LocalOutputPolicy.openTag) {
            candidates.append(Trigger(index: open.lowerBound, kind: .open))
        }
        if let close = text.range(of: LocalOutputPolicy.closeTag) {
            candidates.append(Trigger(index: close.lowerBound, kind: .close))
        }
        if let brace = firstLineInitialBrace(in: text) {
            candidates.append(Trigger(index: brace, kind: .brace))
        }
        return candidates.min { $0.index < $1.index }
    }

    private func firstLineInitialBrace(in text: String) -> String.Index? {
        var lineStart = atLineStart
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" && lineStart { return index }
            if character == "\n" || character == "\r" {
                lineStart = true
            } else if !character.isWhitespace {
                lineStart = false
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func endsAtLineStart(_ text: String) -> Bool {
        for character in text.reversed() {
            if character == "\n" || character == "\r" { return true }
            if !character.isWhitespace { return false }
        }
        return false
    }

    /// Index of the `}` that closes an object starting at the first character, or nil.
    private static func balancedEnd(of text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `tag` — the part that
    /// might still grow into the tag on the next chunk and must be held back.
    private static func partialTagSuffixLength(of text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            if tag.hasPrefix(text.suffix(length)) { return length }
        }
        return 0
    }
}

extension LocalOutputPolicy {
    /// Plan MQ P1: one generation read with the calls the runtime's parser took out of the stream.
    /// A call in the text wins (the shipped protocol); otherwise the runtime's first call is the
    /// turn's call. Until P1 those calls were skipped, so a Hermes-format model's call vanished.
    /// Whatever protocol the text carried is still removed from what is spoken. `invocations`
    /// holds every call the runtime parsed, in order.
    static func classify(_ raw: String, parsedCalls: [LocalToolCallEvent]) -> Classification {
        let classification = classify(raw)
        guard classification.invocation == nil, let first = parsedCalls.first else { return classification }
        return Classification(kind: .toolCall, text: classification.text, invocation: first.invocation,
                              invocations: parsedCalls.map(\.invocation))
    }
}
