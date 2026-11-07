import Foundation

/// Regular expressions in recipe add-ons — an `extract` step's `regex` and a string parameter's
/// `pattern` — and the rules that keep them cheap.
///
/// `NSRegularExpression` is a backtracking engine with no timeout, so a pattern is bounded three
/// ways:
///
/// 1. **Shape, at install** (`issues(in:)`): ≤ 200 characters; no backreferences; counted
///    repeats ≤ 100; and **no quantified group that itself contains a quantifier or an
///    alternation** — `(a+)+`, `(a|aa)+`, `(.*a){12}`. Those nested forms are the exponential
///    class; refusing them costs authors little (a recipe picks one value out of a response).
///    The rule is conservative: `(?:USD|EUR)+` is refused too.
/// 2. **Input**: ≤ 1 MB (the runner's cap).
/// 3. **Time, at run** (`firstCapture`): matching uses `.reportProgress`, whose callback fires
///    periodically inside a long match, and stops once a wall-clock budget is spent. This covers
///    what shape rules can't — polynomial patterns such as `.*.*x` over a large input.
enum RecipeRegex {

    static let maxPatternLength = 200
    static let maxRepeatCount = 100
    static let maxInputBytes = 1_048_576

    enum Issue: Equatable, Sendable {
        case tooLong
        case backreference
        case nestedQuantifier
        case repeatTooLarge
        case doesNotCompile
        case noCaptureGroup
    }

    /// Shape problems with `pattern`; empty when it may be used. `needsCaptureGroup` is true for
    /// an `extract` step (which returns the first capture group).
    static func issues(in pattern: String, needsCaptureGroup: Bool) -> [Issue] {
        guard pattern.count <= maxPatternLength else { return [.tooLong] }
        var issues: [Issue] = []
        let shape = scan(pattern)
        if shape.backreference { issues.append(.backreference) }
        if shape.nestedQuantifier { issues.append(.nestedQuantifier) }
        if shape.repeatTooLarge { issues.append(.repeatTooLarge) }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return issues + [.doesNotCompile] }
        if needsCaptureGroup, regex.numberOfCaptureGroups < 1 { issues.append(.noCaptureGroup) }
        return issues
    }

    // MARK: - Matching under a budget

    enum MatchOutcome: Equatable, Sendable {
        case matched(String)
        case noMatch
        case timedOut
    }

    /// The first capture group (or the whole match when the pattern has none) of the first match
    /// in `text`, stopping once `budget` seconds of `uptime()` have passed. A match whose first
    /// group did not take part counts as `.noMatch`.
    static func firstCapture(of regex: NSRegularExpression, in text: String, budget: TimeInterval,
                             uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> MatchOutcome {
        let ns = text as NSString
        switch firstMatch(of: regex, in: text, budget: budget, uptime: uptime) {
        case .timedOut: return .timedOut
        case .missing: return .noMatch
        case .found(let result):
            let range = regex.numberOfCaptureGroups >= 1 ? result.range(at: 1) : result.range
            return range.location == NSNotFound ? .noMatch : .matched(ns.substring(with: range))
        }
    }

    /// Whether `regex` matches anywhere in `text` within `budget` (parameter patterns, which
    /// authors anchor with `^…$`). Running out of time counts as no match.
    static func matches(_ regex: NSRegularExpression, _ text: String, budget: TimeInterval,
                        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Bool {
        if case .found = firstMatch(of: regex, in: text, budget: budget, uptime: uptime) { return true }
        return false
    }

    private enum RawMatch {
        case found(NSTextCheckingResult)
        case missing
        case timedOut
    }

    private static func firstMatch(of regex: NSRegularExpression, in text: String, budget: TimeInterval,
                                   uptime: () -> TimeInterval) -> RawMatch {
        let deadline = uptime() + budget
        var outcome: RawMatch = .missing
        let length = (text as NSString).length
        regex.enumerateMatches(in: text, options: [.reportProgress],
                               range: NSRange(location: 0, length: length)) { result, _, stop in
            if let result {
                outcome = .found(result)
                stop.pointee = true
            } else if uptime() > deadline {
                outcome = .timedOut
                stop.pointee = true
            }
        }
        return outcome
    }

    // MARK: - Shape scan

    private struct Shape {
        var backreference = false
        var nestedQuantifier = false
        var repeatTooLarge = false
    }

    private struct Group {
        var hasQuantifier = false
        var hasAlternation = false
    }

    private static func scan(_ pattern: String) -> Shape {
        let chars = Array(pattern)
        var shape = Shape()
        var stack: [Group] = [Group()]
        var i = 0

        /// If a quantifier starts at `j`, its length and whether it can repeat more than once.
        func quantifier(at j: Int) -> (length: Int, repeats: Bool)? {
            guard j < chars.count else { return nil }
            let base: (length: Int, repeats: Bool)
            switch chars[j] {
            case "*", "+": base = (1, true)
            case "?": base = (1, false)
            case "{":
                guard let close = chars[j...].firstIndex(of: "}") else { return nil }
                let body = String(chars[(j + 1)..<close])
                let bounds = body.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard (1...2).contains(bounds.count), let low = Int(bounds[0]) else { return nil }
                let high: Int? = bounds.count == 1 ? low : (bounds[1].isEmpty ? nil : Int(bounds[1]))
                if bounds.count == 2, !bounds[1].isEmpty, high == nil { return nil }
                if low > maxRepeatCount || (high ?? 0) > maxRepeatCount { shape.repeatTooLarge = true }
                base = (close - j + 1, high == nil || (high ?? 0) > 1)
            default:
                return nil
            }
            var length = base.length
            // Lazy (`*?`) and possessive (`*+`) modifiers belong to the same quantifier.
            if j + length < chars.count, chars[j + length] == "?" || chars[j + length] == "+" { length += 1 }
            return (length, base.repeats)
        }

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\\":
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next.isNumber, next != "0" { shape.backreference = true }
                    if next == "k", i + 2 < chars.count, chars[i + 2] == "<" { shape.backreference = true }
                }
                i += 2
                if let q = quantifier(at: i) { stack[stack.count - 1].hasQuantifier = true; i += q.length }
                continue
            case "[":
                // Skip the character class (nested sets and escapes included).
                var depth = 0
                var j = i
                while j < chars.count {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "[" { depth += 1 }
                    if chars[j] == "]", j > i + 1 || depth > 1 { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                i = j + 1
                if let q = quantifier(at: i) { stack[stack.count - 1].hasQuantifier = true; i += q.length }
                continue
            case "(":
                stack.append(Group())
                i += 1
                // `(?:`, `(?i)`, lookarounds, named groups: the `?` is a group modifier.
                if i < chars.count, chars[i] == "?" {
                    i += 1
                    if i < chars.count, chars[i] == "<", i + 1 < chars.count, chars[i + 1] != "=", chars[i + 1] != "!" {
                        while i < chars.count, chars[i] != ">" { i += 1 }
                    }
                    i += 1
                }
                continue
            case ")":
                let group = stack.count > 1 ? stack.removeLast() : Group()
                i += 1
                var quantified = false
                if let q = quantifier(at: i) {
                    quantified = true
                    if q.repeats, group.hasQuantifier || group.hasAlternation { shape.nestedQuantifier = true }
                    i += q.length
                }
                stack[stack.count - 1].hasQuantifier = stack[stack.count - 1].hasQuantifier || group.hasQuantifier || quantified
                stack[stack.count - 1].hasAlternation = stack[stack.count - 1].hasAlternation || group.hasAlternation
                continue
            case "|":
                stack[stack.count - 1].hasAlternation = true
                i += 1
                continue
            default:
                i += 1
                if let q = quantifier(at: i) { stack[stack.count - 1].hasQuantifier = true; i += q.length }
            }
        }
        return shape
    }
}
