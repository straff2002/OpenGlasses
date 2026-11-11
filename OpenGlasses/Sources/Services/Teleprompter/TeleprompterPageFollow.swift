import Foundation

/// Plan KX §6: teleprompter voice-follow — the page turns when the phone's mic hears its last words.
///
/// **What it is.** An opt-in way to run the audio-paced mode (`Config.teleprompterPageFollow`, off
/// by default). The plain audio-paced mode moves the window a line at a time as the aligner tracks
/// the reader, which on the Meta Display is a send per line and a window that moves under the eye.
/// Voice-follow holds a whole page still and turns it once, when the reader reaches its end: one
/// send a page, and a page that does not move while it is read.
///
/// **A page** starts at the cursor's word (not the start of its source line, so a page that ended
/// mid-line does not show the read half again) and holds as many words as fit the window's lines
/// (`page(_:from:geometry:)`). **Its end** is its last `tailLength` (5) words, normalised as the
/// script and the recogniser already are (`TeleprompterText`).
///
/// **The match** (`heardEnd(of:in:)`) is fuzzy and local: only the newest heard words count (the
/// tail's length plus two), the reader must be at the end (the newest heard word is one of the page's
/// last two), and the tail's words must appear in order among them, one of them allowed to be
/// missing or misheard when the tail has four or more. Two words are the same when they normalise
/// alike, one is the other with an "s", or — for words of four letters or more — they are one edit
/// apart. Pure.
///
/// **The mic** is the audio-paced mode's: the recognition shell taps the shared audio engine
/// (`WakeWordService`), whose input follows `Config.conversationMicRoute` — so with the Meta Display
/// on, Glasses Mic becomes the iPhone's mic (Plan KX §2.5), and the hands-free link that would end
/// the display session is never opened for it.
enum TeleprompterPageFollow {
    /// How many of the page's last words are listened for.
    static let tailLength = 5
    /// Heard words looked at beyond the tail's length.
    static let slack = 2

    /// The page that starts at `cursor`: its display lines and the token range they show.
    static func page(_ script: TeleprompterScript, from cursor: Int,
                     geometry: TeleprompterPaginator.Geometry) -> (window: TeleprompterWindow, range: Range<Int>) {
        let tokens = script.tokens
        let start = min(max(cursor, 0), tokens.count)
        let progress = tokens.isEmpty ? 1.0 : Double(start) / Double(tokens.count)
        guard start < tokens.count, geometry.maxLines > 0, geometry.maxChars > 0 else {
            return (TeleprompterWindow(lines: [], activeLineIndex: 0, progress: progress), start..<start)
        }
        var lines: [String] = []
        var current = ""
        var sourceLine = tokens[start].line
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            let word = String(token.text.prefix(geometry.maxChars))
            if token.line != sourceLine, !current.isEmpty {
                lines.append(current)
                current = ""
            }
            sourceLine = token.line
            if lines.count >= geometry.maxLines { break }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= geometry.maxChars {
                current += " " + word
            } else {
                lines.append(current)
                current = ""
                if lines.count >= geometry.maxLines { break }
                current = word
            }
            index += 1
        }
        if !current.isEmpty, lines.count < geometry.maxLines { lines.append(current) }
        return (TeleprompterWindow(lines: lines, activeLineIndex: 0, progress: progress), start..<index)
    }

    /// The page's end as the recogniser would hear it: its last `tailLength` normalised words.
    static func tail(_ script: TeleprompterScript, range: Range<Int>) -> [String] {
        guard !range.isEmpty, range.upperBound <= script.tokens.count else { return [] }
        return script.tokens[range].suffix(tailLength).map(\.normalized)
    }

    /// Whether the newest of `heard` (normalised) reach the end of a page whose last words are
    /// `tail`.
    static func heardEnd(of tail: [String], in heard: [String]) -> Bool {
        guard !tail.isEmpty, let newest = heard.last else { return false }
        guard tail.suffix(2).contains(where: { wordsMatch($0, newest) }) else { return false }
        let window = Array(heard.suffix(tail.count + slack))
        let allowedMisses = tail.count >= 4 ? 1 : 0
        return inOrderMatches(tail, window) >= tail.count - allowedMisses
    }

    /// Two normalised words are the same word, as far as following a reader goes.
    static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a + "s" == b || b + "s" == a { return true }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(a, b) <= 1
    }

    /// The longest run of `tail`'s words found in order in `heard` (gaps allowed).
    static func inOrderMatches(_ tail: [String], _ heard: [String]) -> Int {
        guard !tail.isEmpty, !heard.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: heard.count + 1)
        for word in tail {
            var row = [Int](repeating: 0, count: heard.count + 1)
            for (j, said) in heard.enumerated() {
                row[j + 1] = wordsMatch(word, said) ? previous[j] + 1 : max(previous[j + 1], row[j])
            }
            previous = row
        }
        return previous[heard.count]
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var next = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return row[b.count]
    }
}

/// Plan KX §6: what voice-follow has heard of the current recognition. A recogniser's partial
/// results grow within one utterance, so the words that turned a page are set aside: the next page
/// is matched only on words heard after them. A shorter result is a new utterance and starts over.
struct TeleprompterPageFollower: Equatable {
    private(set) var consumed = 0

    /// Feed the recogniser's whole result so far; true when it reaches the end of `tail`.
    mutating func hear(_ heard: [String], tail: [String]) -> Bool {
        if heard.count < consumed { consumed = 0 }
        let fresh = Array(heard.dropFirst(consumed))
        guard TeleprompterPageFollow.heardEnd(of: tail, in: fresh) else { return false }
        consumed = heard.count
        return true
    }

    /// A new recognition began.
    mutating func reset() { consumed = 0 }
}
