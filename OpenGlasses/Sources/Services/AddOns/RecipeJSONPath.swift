import Foundation

/// The JSONPath subset recipe add-ons extract with: `$`, `.key`, `['key']`, `[n]` and `[*]`.
/// No filters, slices, recursive descent or scripts.
///
/// A path is parsed once into `segments` and then walked over values as `JSONSerialization`
/// produces them (`[String: Any]`, `[Any]`, `String`, `NSNumber`, `NSNull`). The harness
/// `JSONPath` dot-paths (`"data.run.id"`) walk through the same type, built from key segments
/// only — see `init(dotKeys:)`.
struct RecipeJSONPath: Equatable, Sendable {

    enum Segment: Equatable, Sendable {
        case key(String)
        case index(Int)
        case wildcard
    }

    enum ParseError: Error, Equatable, Sendable {
        case mustStartWithDollar
        case emptyKey(position: Int)
        case unterminatedBracket(position: Int)
        case invalidIndex(String)
        case unexpectedCharacter(Character, position: Int)
        case tooLong
        case tooManySegments
    }

    static let maxLength = 200
    static let maxSegments = 16
    /// The most values a wildcard path returns (the step's `limit` may lower it).
    static let maxResults = 10

    let segments: [Segment]

    init(segments: [Segment]) { self.segments = segments }

    /// A path of plain object keys, one per dot-separated component — the harness `JSONPath`
    /// grammar. Components are taken literally: `"files[0]"` is a key named `files[0]`, not an
    /// index, and `"*"` is a key named `*`, exactly as the harness has always read them.
    init(dotKeys path: String) {
        self.segments = path.split(separator: ".").map { .key(String($0)) }
    }

    var hasWildcard: Bool { segments.contains(.wildcard) }

    // MARK: - Parsing

    static func parse(_ text: String) -> Result<RecipeJSONPath, ParseError> {
        guard text.count <= maxLength else { return .failure(.tooLong) }
        let chars = Array(text)
        guard chars.first == "$" else { return .failure(.mustStartWithDollar) }
        var segments: [Segment] = []
        var i = 1
        while i < chars.count {
            switch chars[i] {
            case ".":
                var j = i + 1
                var key = ""
                while j < chars.count, chars[j] != ".", chars[j] != "[", chars[j] != "]" {
                    key.append(chars[j]); j += 1
                }
                guard !key.isEmpty else { return .failure(.emptyKey(position: i)) }
                segments.append(key == "*" ? .wildcard : .key(key))
                i = j
            case "[":
                guard let close = chars[(i + 1)...].firstIndex(of: "]") else {
                    return .failure(.unterminatedBracket(position: i))
                }
                let inner = String(chars[(i + 1)..<close])
                if inner == "*" {
                    segments.append(.wildcard)
                } else if inner.count >= 2, inner.first == "'", inner.last == "'" {
                    let key = String(inner.dropFirst().dropLast())
                    guard !key.isEmpty else { return .failure(.emptyKey(position: i)) }
                    guard !key.contains("'") else { return .failure(.unexpectedCharacter("'", position: i)) }
                    segments.append(.key(key))
                } else {
                    guard !inner.isEmpty, inner.count <= 6, inner.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let n = Int(inner) else { return .failure(.invalidIndex(inner)) }
                    segments.append(.index(n))
                }
                i = close + 1
            default:
                return .failure(.unexpectedCharacter(chars[i], position: i))
            }
            if segments.count > maxSegments { return .failure(.tooManySegments) }
        }
        return .success(RecipeJSONPath(segments: segments))
    }

    // MARK: - Evaluation

    /// Every value the path reaches, in document order (object wildcards in sorted-key order, so
    /// the result is deterministic). Missing keys, out-of-range indexes and walking past a leaf
    /// reach nothing.
    func values(in root: Any) -> [Any] {
        var current: [Any] = [root]
        for segment in segments {
            var next: [Any] = []
            for value in current {
                switch segment {
                case .key(let key):
                    if let dict = value as? [String: Any], let child = dict[key] { next.append(child) }
                case .index(let n):
                    if let array = value as? [Any], n >= 0, n < array.count { next.append(array[n]) }
                case .wildcard:
                    if let array = value as? [Any] {
                        next.append(contentsOf: array)
                    } else if let dict = value as? [String: Any] {
                        next.append(contentsOf: dict.keys.sorted().compactMap { dict[$0] })
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }
        return current
    }

    /// The single value at the path (the first one for a wildcard path), or `nil`.
    func value(in root: Any) -> Any? { values(in: root).first }

    /// The value(s) as text: scalars coerced by `Self.text(of:)`; an array of scalars reached
    /// without a wildcard counts as its elements. Objects, nulls and nested arrays are skipped.
    /// At most `limit` (clamped to 1…`maxResults`) values.
    func strings(in root: Any, limit: Int = maxResults) -> [String] {
        let cap = min(max(limit, 1), Self.maxResults)
        var out: [String] = []
        for value in values(in: root) {
            if let array = value as? [Any] {
                for element in array {
                    if let s = Self.text(of: element) { out.append(s) }
                    if out.count >= cap { return out }
                }
            } else if let s = Self.text(of: value) {
                out.append(s)
            }
            if out.count >= cap { return out }
        }
        return out
    }

    /// A scalar JSON value as text: strings as they are, booleans as `true`/`false`, integral
    /// numbers without a trailing `.0`, others in their shortest round-trip form. `nil` for
    /// objects, arrays and null.
    ///
    /// `JSONSerialization` hands back `NSNumber` for both numbers and booleans, so a boolean is
    /// told apart by its CoreFoundation type, not by `as? Bool` (which also accepts 0 and 1).
    static func text(of value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return numberText(n)
        default:
            return nil
        }
    }

    static func numberText(_ n: NSNumber) -> String {
        let type = String(cString: n.objCType)
        if type != "d" && type != "f" { return n.stringValue }   // an integer type
        return numberText(n.doubleValue)
    }

    static func numberText(_ d: Double) -> String {
        guard d.isFinite else { return "" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }
}

// MARK: - Templated paths

extension RecipeJSONPath {

    /// Parse a path that contains `{{name}}` placeholders, such as `$.rates.{{to}}`.
    ///
    /// The structure is parsed from the author's literal text alone: each placeholder stands in as
    /// an opaque token while parsing, so it may only sit inside a key (`.{{to}}` or `['{{to}}']`),
    /// never in an index or between segments. With `values`, each token is then replaced by its
    /// value **as literal key text** — a `.` or `[` in a value is part of the key name and cannot
    /// add a segment. Without `values` (install-time validation), tokens are left in place.
    static func parse(template: RecipeTemplate, values: [String: String]? = nil) -> Result<RecipeJSONPath, ParseError> {
        var text = ""
        var names: [String] = []
        for part in template.parts {
            switch part {
            case .literal(let s): text += s
            case .variable(let name):
                text += "\u{E000}\(names.count)\u{E001}"
                names.append(name)
            }
        }
        switch parse(text) {
        case .failure(let error):
            return .failure(error)
        case .success(let path):
            guard let values else { return .success(path) }
            let resolved = path.segments.map { segment -> Segment in
                guard case .key(var key) = segment else { return segment }
                for (i, name) in names.enumerated() {
                    key = key.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: values[name] ?? "")
                }
                return .key(key)
            }
            return .success(RecipeJSONPath(segments: resolved))
        }
    }
}
