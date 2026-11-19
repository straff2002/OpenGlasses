import Foundation

/// Which line of the van somebody means (Plan IH §2).
///
/// Deducting is the easy direction — what was said only has to match one of the lines on this van
/// — and this is what makes it easy. In order:
///
/// 1. a scanned code already attached to a line;
/// 2. the part number exactly, then the vault's supersession in both directions;
/// 3. the words of the description: every word said is one of the line's. A number the recogniser
///    broke up ("2 50" for "250", "1 200" for "1200") is tried put back together as well as the
///    way it was heard, and either way is a match word for word;
/// 4. failing that, a near miss: every word said but one is the line's, at least two of them are,
///    and the one left over sounds like a word of the line the technician did not say — the
///    recogniser heard a brand as the common word it sounds like. Never a number: a different
///    number is a different part.
///
/// Several candidates are handed back to be asked about, and near misses always are, however
/// many there are. It never picks one.
///
/// Pure over the lines and a parts index, so it runs headless with no store around it.
struct VanStockMatcher {

    enum Match: Equatable {
        case one(VanStockItem)
        /// More than one line fits. The technician is asked which.
        case several([VanStockItem])
        /// Nothing fits word for word, but these lines would if one misheard word were what it
        /// sounds like. Asked about, never acted on: a build-728 tester's request for a line by its
        /// brand was heard with the brand as an everyday word and was answered "none on the van"
        /// while 22 packs were on it.
        case near([VanStockItem])
        case none
    }

    let items: [VanStockItem]
    /// The vault's parts table, for superseded numbers. Empty when there is no vault to ask.
    var partsIndex = VaultPartsIndex(files: [])

    func match(number: String? = nil, description: String? = nil, code: String? = nil) -> Match {
        if let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty,
           let item = items.first(where: { $0.codes.contains(code) }) {
            return .one(item)
        }

        let wanted = number.map(VaultPartsIndex.normalise).flatMap { $0.isEmpty ? nil : $0 }
        if let wanted {
            let exact = items.filter { $0.number == wanted }
            if let found = Self.result(exact) { return found }
            if let found = Self.result(superseded(wanted)) { return found }
        }

        // The words. With no description, what was given as a number is tried as words, because
        // "45/5 capacitor" arrives in whichever argument the model chose.
        let said = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heard = Self.saidTokens(said.isEmpty ? (number ?? "") : said)
        guard !heard.isEmpty else { return .none }
        let eligible = items.filter { item in
            // A different number is a different part, however alike the descriptions are.
            if !said.isEmpty, let wanted, let own = item.number, own != wanted { return false }
            return true
        }
        let owned = eligible.map { item in
            (item: item, own: Self.tokens("\(item.description) \(item.number ?? "") \(item.bin ?? "")"))
        }
        let described = owned.filter { line in heard.contains { $0.isSubset(of: line.own) } }.map(\.item)
        if let found = Self.result(described) { return found }

        let near = owned.filter { line in heard.contains { Self.isNearMiss($0, of: line.own) } }.map(\.item)
        return near.isEmpty ? .none : .near(near)
    }

    /// Lines the vault says are the same part under another number: the number printed on the old
    /// component finds the stock of its replacement, and the new number finds old stock.
    private func superseded(_ wanted: String) -> [VanStockItem] {
        let replacement = partsIndex.part(number: wanted).map { VaultPartsIndex.normalise($0.number) }
        return items.filter { item in
            guard let own = item.number, own != wanted else { return false }
            if own == replacement { return true }
            return partsIndex.part(number: own).map { VaultPartsIndex.normalise($0.number) } == wanted
        }
    }

    private static func result(_ found: [VanStockItem]) -> Match? {
        switch found.count {
        case 0: return nil
        case 1: return .one(found[0])
        default: return .several(found)
        }
    }

    // MARK: - Words

    /// Words that say nothing about which part is meant.
    private static let filler: Set<String> = [
        "a", "an", "the", "of", "for", "my", "some", "any", "part", "number", "one", "ones", "and",
    ]

    /// Lowercased letter-and-digit runs, plural "s" dropped, filler removed. "45/5 capacitors" and
    /// "Capacitor, dual run, 45/5 µF" share `45`, `5` and `capacitor`.
    static func tokens(_ text: String) -> Set<String> {
        words(runs(text).map(\.run))
    }

    private static func words(_ runs: [String]) -> Set<String> {
        Set(runs.compactMap { run in
            let word = run.count > 3 && run.hasSuffix("s") && !run.hasSuffix("ss") ? String(run.dropLast()) : run
            return filler.contains(word) ? nil : word
        })
    }

    /// Each letter-and-digit run, with what separated it from the run before.
    private static func runs(_ text: String) -> [(run: String, gap: String)] {
        var found: [(run: String, gap: String)] = []
        var current = ""
        var gap = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { found.append((current, gap)); current = ""; gap = "" }
                gap.append(character)
            }
        }
        if !current.isEmpty { found.append((current, gap)) }
        return found
    }

    /// The most ways one run of spoken digits is put back together, and the most readings of a
    /// whole phrase; past either, only the words as heard and with every broken number rejoined.
    private static let longestBrokenNumber = 4
    private static let mostReadings = 16

    /// What was said as words: first as heard, then with each number the recogniser broke at a
    /// space put back together every way it can be ("6 x 2 50" is also `6 x 250`; the "x" keeps the
    /// 8 apart). The reading as heard is always kept, so "2 4" still finds "2 x 4".
    static func saidTokens(_ text: String) -> [Set<String>] {
        // Pieces of the phrase: a word on its own, or digit runs with only spaces between them.
        var pieces: [[String]] = []
        for (run, gap) in runs(text) {
            let digits = run.allSatisfy(\.isNumber)
            if digits, !gap.isEmpty, gap.allSatisfy(\.isWhitespace),
               let previous = pieces.last?.last, previous.allSatisfy(\.isNumber) {
                pieces[pieces.count - 1].append(run)
            } else {
                pieces.append([run])
            }
        }
        let options = pieces.map { piece -> [[String]] in
            guard piece.count > 1 else { return [piece] }
            guard piece.count <= longestBrokenNumber else { return [piece, [piece.joined()]] }
            return joinings(piece)
        }
        let product = options.reduce(1) { $0 * $1.count }
        let readings: [[String]]
        if product <= mostReadings {
            readings = options.reduce([[]]) { partial, choices in
                partial.flatMap { reading in choices.map { reading + $0 } }
            }
        } else {
            readings = [pieces.flatMap { $0 }, pieces.map { $0.joined() }]
        }
        var seen: [Set<String>] = []
        for reading in readings {
            let set = words(reading)
            if !set.isEmpty, !seen.contains(set) { seen.append(set) }
        }
        return seen
    }

    /// Every way to join neighbouring runs of one broken number, as heard first: ["2", "50"] gives
    /// ["2", "50"] and ["250"].
    private static func joinings(_ runs: [String]) -> [[String]] {
        guard let first = runs.first else { return [[]] }
        var results: [[String]] = [[first]]
        for run in runs.dropFirst() {
            results = results.flatMap { result in
                [result + [run], Array(result.dropLast()) + [result[result.count - 1] + run]]
            }
        }
        return results
    }

    // MARK: - Near misses

    /// Every word said but one is the line's, at least two are, and the one left over sounds like
    /// a word of the line that nobody said. Neither of the two is a number.
    static func isNearMiss(_ said: Set<String>, of own: Set<String>) -> Bool {
        let unmatched = said.subtracting(own)
        guard unmatched.count == 1, let heard = unmatched.first, said.count - 1 >= 2,
              !heard.contains(where: \.isNumber) else { return false }
        return own.subtracting(said).contains { word in
            !word.contains(where: \.isNumber) && soundsAlike(heard, word)
        }
    }

    /// The same sound by `soundKey`, or the same word but for a slip of the recogniser: within one
    /// edit for a word of four or five letters and two for a longer one. One edit in four letters
    /// is already a quarter of the word; below four, a single letter makes another word
    /// ("cap"/"cat"), so short words must sound the same. A closing s sound is left out of the
    /// comparison, because `tokens` has already taken a plural-looking "s" off one of the two
    /// ("kwarts" is `kwart`, "quartz" keeps its z).
    static func soundsAlike(_ heard: String, _ word: String) -> Bool {
        guard heard.count >= 3, word.count >= 3 else { return false }
        func stem(_ key: String) -> String { key.hasSuffix("S") ? String(key.dropLast()) : key }
        let key = stem(soundKey(heard))
        if key.count >= 2, key == stem(soundKey(word)) { return true }
        let shorter = min(heard.count, word.count)
        guard shorter >= 4 else { return false }
        return distance(heard, word) <= (shorter <= 5 ? 1 : 2)
    }

    /// A small phonetic key, Soundex-like but with the first letter coded too, so that "quartz"
    /// and a "kwartz" brand both read `KRTS`: consonants by the sound they make (a hard c, k, q and g
    /// are one; s, z and a soft c another; b/p, d/t, f/v/ph, m/n), vowels and h, w, y dropped
    /// after the start, and a repeated sound said once.
    static func soundKey(_ word: String) -> String {
        let letters = Array(word.lowercased().filter { $0.isLetter })
        var codes: [Character] = []
        func say(_ code: Character) { if codes.last != code { codes.append(code) } }
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            var step = 1
            switch letter {
            case "a", "e", "i", "o", "u": if index == 0 { say("A") }
            case "h", "w", "y": break
            case "p" where next == "h": say("F"); step = 2
            case "f", "v": say("F")
            case "b", "p": say("B")
            case "d", "t": say("T")
            case "c" where next == "k" || next == "h": say("K"); step = 2
            case "c" where next == "e" || next == "i" || next == "y": say("S")
            case "s" where next == "h": say("S"); step = 2
            case "c", "k", "q", "g": say("K")
            case "s", "z": say("S")
            case "x": say("K"); say("S")
            case "j": say("J")
            case "l": say("L")
            case "m", "n": say("N")
            case "r": say("R")
            default: break
            }
            index += step
        }
        return String(codes)
    }

    /// Letters changed, added or dropped to turn one word into the other.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
