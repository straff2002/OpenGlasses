import Foundation

/// A number said as words — "ninety-nine", "one hundred and two" — read where it starts in a
/// sentence (Plan JJ P1, shared since Plan KR P1).
///
/// `TableReference` reads a table's number this way; `PageReference` reads a page's, and a page
/// is also said in digit groups the way page numbers are read aloud: "four twenty-seven" (427),
/// "four oh eight" (408), "three twelve" (312). Groups are read only when the caller asks
/// (`digitGroups`), because "table five A" and "table three two" are not three-digit tables.
///
/// Pure and deterministic.
enum SpokenNumber {

    static let units: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    /// What a zero is said as inside a page number ("four oh eight").
    private static let zeros: Set<String> = ["oh", "o", "zero"]

    /// The next word, after spaces or a hyphen.
    private static let spokenWord = try! NSRegularExpression(pattern: #"[\s\-]*(\p{L}+)"#)

    /// A number written as words starting at `start` (a UTF-16 offset), and where it ends, or nil
    /// when the next word is not a number.
    static func read(in text: NSString, from start: Int, digitGroups: Bool = false) -> (value: Int, end: Int)? {
        // The words that follow, each with where it ends; a hyphen joins two as a space does.
        var words: [(word: String, end: Int)] = []
        var cursor = start
        while words.count < 6, cursor <= text.length,
              let m = spokenWord.firstMatch(in: text as String, options: [.anchored],
                                            range: NSRange(location: cursor, length: text.length - cursor)) {
            words.append((text.substring(with: m.range(at: 1)).lowercased(), NSMaxRange(m.range)))
            cursor = NSMaxRange(m.range)
        }
        var index = 0
        var value = 0
        var end: Int?
        func word(_ i: Int) -> String? { i < words.count ? words[i].word : nil }

        // [one–nine] hundred [and]
        if let w = word(0), let u = units[w], u < 10, word(1) == "hundred" {
            value = u * 100
            end = words[1].end
            index = 2
            if word(index) == "and" { index += 1 }
        } else if word(0) == "hundred" || (word(0) == "a" && word(1) == "hundred") {
            value = 100
            index = word(0) == "a" ? 2 : 1
            end = words[index - 1].end
            if word(index) == "and" { index += 1 }
        } else if digitGroups, let w = word(0), let u = units[w], u < 10, let group = trailingPair(words, from: 1) {
            // "four twenty-seven", "three twelve", "four oh eight": a digit, then the last two.
            return (u * 100 + group.value, group.end)
        }
        // twenty–ninety [one–nine] | one–nineteen
        if let w = word(index), let t = tens[w] {
            value += t
            end = words[index].end
            if let next = word(index + 1), let u = units[next], u < 10 {
                value += u
                end = words[index + 1].end
            }
        } else if let w = word(index), let u = units[w] {
            value += u
            end = words[index].end
        }
        return end.map { (value, $0) }
    }

    /// The two digits after a page's first ("ninety-nine", "twelve", "oh five"), or nil.
    private static func trailingPair(_ words: [(word: String, end: Int)], from i: Int) -> (value: Int, end: Int)? {
        guard i < words.count else { return nil }
        let first = words[i].word
        if let t = tens[first] {
            if i + 1 < words.count, let u = units[words[i + 1].word], u < 10 {
                return (t + u, words[i + 1].end)
            }
            return (t, words[i].end)
        }
        if let teen = units[first], teen >= 10 { return (teen, words[i].end) }
        if zeros.contains(first), i + 1 < words.count, let u = units[words[i + 1].word], u < 10 {
            return (u, words[i + 1].end)
        }
        return nil
    }

    /// The whole of `text` read as one spoken number ("four twenty-seven"), or nil when anything
    /// but the number is in it.
    static func whole(_ text: String, digitGroups: Bool = true) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        guard ns.length > 0, let read = read(in: ns, from: 0, digitGroups: digitGroups),
              read.end == ns.length else { return nil }
        return read.value
    }
}
