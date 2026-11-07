import Foundation

/// A recipe add-on template: literal text with `{{name}}` placeholders and nothing else — no
/// expressions, no filters, no defaults.
///
/// Escaping is chosen by **where** a value lands, never by the author: the engine renders a
/// parameter into a URL path segment, a query value, a form field, a JSON string, a header value
/// or plain speech text, and each context has its own rule (`Context`). A value can therefore
/// never change the structure of the thing it is placed in: a `&`, `#`, `?`, `/` or `%` in a
/// parameter stays inside its query value, a `"` stays inside its JSON string, and a CR/LF can't
/// start a new header.
struct RecipeTemplate: Equatable, Sendable {

    enum Part: Equatable, Sendable {
        case literal(String)
        case variable(String)
    }

    enum ParseError: Error, Equatable, Sendable {
        /// `{{` with no closing `}}`.
        case unclosedPlaceholder
        /// `{{}}`, or a name that is not `letter-or-underscore` then letters, digits, `_` and
        /// single dots (`fx.status`).
        case invalidName(String)
    }

    /// Where a substituted value lands, which decides how it is escaped.
    enum Context: Sendable {
        /// Speech (`say`), display cards, memory values: the value as is, minus control characters
        /// other than newline and tab.
        case plain
        /// One URL path segment: everything but RFC 3986 unreserved characters is percent-encoded,
        /// including `/`, and a value made only of dots is encoded so it cannot walk up the path.
        case urlPathSegment
        /// One query key or value: everything but unreserved characters is percent-encoded, so `&`,
        /// `=`, `#`, `+`, `%` and space can never split or end the query.
        case urlQueryValue
        /// An `application/x-www-form-urlencoded` key or value (same rule as a query value).
        case formValue
        /// The inside of a JSON string literal (no surrounding quotes).
        case jsonString
        /// An HTTP header value: every control character (CR and LF included) is removed.
        case headerValue
    }

    let parts: [Part]

    init(parts: [Part]) { self.parts = parts }

    /// A template with no placeholders.
    init(literal: String) { self.parts = literal.isEmpty ? [] : [.literal(literal)] }

    /// Parse `text`. Single braces are literal; `{{` always opens a placeholder.
    static func parse(_ text: String) -> Result<RecipeTemplate, ParseError> {
        var parts: [Part] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            if open.lowerBound > rest.startIndex {
                parts.append(.literal(String(rest[rest.startIndex..<open.lowerBound])))
            }
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else { return .failure(.unclosedPlaceholder) }
            let name = afterOpen[afterOpen.startIndex..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard isValidVariableName(name) else { return .failure(.invalidName(name)) }
            parts.append(.variable(name))
            rest = afterOpen[close.upperBound...]
        }
        if !rest.isEmpty { parts.append(.literal(String(rest))) }
        return .success(RecipeTemplate(parts: parts))
    }

    /// Variable names this template references, in first-use order, without duplicates.
    var variableNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for case .variable(let name) in parts where seen.insert(name).inserted { out.append(name) }
        return out
    }

    var hasVariables: Bool { parts.contains { if case .variable = $0 { return true }; return false } }

    /// The literal text only (placeholders dropped) — used for static length checks.
    var literalLength: Int {
        parts.reduce(0) { sum, part in
            if case .literal(let s) = part { return sum + s.count }
            return sum
        }
    }

    /// Render every placeholder in one context. A variable missing from `values` renders empty
    /// (the validator refuses a template whose variable is not defined by then).
    func render(_ values: [String: String], context: Context) -> String {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let s): out += s
            case .variable(let name): out += Self.escape(values[name] ?? "", for: context)
            }
        }
        return out
    }

    // MARK: - URL templates

    /// The section of a URL a placeholder sits in, decided by the literal text before it.
    enum URLSection: Equatable, Sendable {
        case beforeAuthority, authority, path, query, fragment
    }

    /// Render a URL template. The URL's structure comes only from the author's literal text: each
    /// placeholder is escaped for the section the literal text has reached (path segment before
    /// `?`, query value after it). A placeholder in the scheme or host is rendered path-escaped
    /// here, but the validator refuses it and the sandbox re-checks the host after substitution.
    func renderURL(_ values: [String: String]) -> String {
        var out = ""
        var scanner = URLSectionScanner()
        for part in parts {
            switch part {
            case .literal(let s):
                out += s
                scanner.consume(s)
            case .variable(let name):
                let value = values[name] ?? ""
                switch scanner.section {
                case .query, .fragment: out += Self.escape(value, for: .urlQueryValue)
                default: out += Self.escape(value, for: .urlPathSegment)
                }
            }
        }
        return out
    }

    /// Whether any placeholder falls before the path starts — in the scheme, userinfo, host or
    /// port. Hosts must be literal so the allowlist can be checked at install.
    var placesVariableBeforePath: Bool {
        var scanner = URLSectionScanner()
        for part in parts {
            switch part {
            case .literal(let s): scanner.consume(s)
            case .variable:
                if scanner.section == .beforeAuthority || scanner.section == .authority { return true }
            }
        }
        return false
    }

    /// Tracks which URL section the literal text has reached, character by character.
    struct URLSectionScanner {
        private(set) var section: URLSection = .beforeAuthority
        private var recent: [Character] = []

        mutating func consume(_ text: String) {
            for ch in text {
                switch section {
                case .beforeAuthority:
                    recent.append(ch)
                    if recent.count > 3 { recent.removeFirst() }
                    if recent == [":", "/", "/"] { section = .authority }
                case .authority:
                    if ch == "/" { section = .path } else if ch == "?" { section = .query } else if ch == "#" { section = .fragment }
                case .path:
                    if ch == "?" { section = .query } else if ch == "#" { section = .fragment }
                case .query:
                    if ch == "#" { section = .fragment }
                case .fragment:
                    break
                }
            }
        }
    }

    // MARK: - Escaping

    /// RFC 3986 unreserved characters — the only ones left unencoded in URL and form contexts.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return set
    }()

    static func escape(_ value: String, for context: Context) -> String {
        switch context {
        case .plain:
            return String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
                scalar == "\n" || scalar == "\t" || !isControl(scalar)
            }))
        case .headerValue:
            return String(String.UnicodeScalarView(value.unicodeScalars.filter { !isControl($0) }))
        case .urlQueryValue, .formValue:
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        case .urlPathSegment:
            // "." and ".." are path navigation, not names; encode them so a value can't climb.
            if !value.isEmpty, value.allSatisfy({ $0 == "." }) {
                return String(repeating: "%2E", count: value.count)
            }
            return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        case .jsonString:
            return jsonStringEscaped(value)
        }
    }

    /// The JSON-string-literal escaping of `value`, without the surrounding quotes. Escapes `"`,
    /// `\`, every C0 control character, DEL and the two JavaScript line separators.
    static func jsonStringEscaped(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
            || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    // MARK: - Names

    /// `fx`, `fx.status`, `_tmp2` — letter or underscore first, then letters, digits and `_`, with
    /// single dots between segments. ASCII only, ≤ 64 characters.
    static func isValidVariableName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        for segment in name.split(separator: ".", omittingEmptySubsequences: false) {
            guard let first = segment.unicodeScalars.first,
                  first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
            for scalar in segment.unicodeScalars {
                guard scalar.isASCII, scalar == "_" || CharacterSet.alphanumerics.contains(scalar) else { return false }
            }
        }
        return true
    }
}
