import Foundation

// Plan KT §4.3 — "in your voice". A small style note the wearer can read and edit, and a learner
// that watches how they edit drafts before handing them off. The learner keeps counts only, never
// a message; after three consistent edits it proposes one change to the note, which the wearer
// accepts or ignores. Nothing is learned from the wearer's own messages or mail.

/// The style note.
struct WritingStyle: Codable, Equatable, Sendable {
    enum Greeting: String, Codable, CaseIterable, Sendable {
        /// Whatever the draft's own wording does.
        case asWritten
        /// Open with "Hi {name}".
        case hiName
        /// No greeting.
        case none
    }

    enum Length: String, Codable, CaseIterable, Sendable {
        case short
        case asNeeded
    }

    enum Formality: String, Codable, CaseIterable, Sendable {
        case casual
        case neutral
        case formal
    }

    /// The free line and the sign-off are cut to this many characters.
    static let freeLineLimit = 120
    static let signOffLimit = 40

    var greeting: Greeting = .asWritten
    /// "Cheers, Sam". Empty: the draft's own sign-off, if it has one.
    var signOff: String = "" { didSet { signOff = Self.clipped(signOff, Self.signOffLimit) } }
    var length: Length = .asNeeded
    var formality: Formality = .neutral
    var emoji = false
    /// "I never use exclamation marks."
    var freeLine: String = "" { didSet { freeLine = Self.clipped(freeLine, Self.freeLineLimit) } }

    static let standard = WritingStyle()

    var isStandard: Bool { self == .standard }

    /// The note as lines for a model's instructions. Each is the wearer's own preference.
    var promptLines: [String] {
        var lines: [String] = []
        switch greeting {
        case .asWritten: break
        case .hiName: lines.append("Open with \"Hi\" and the person's first name.")
        case .none: lines.append("Do not open with a greeting.")
        }
        let sign = signOff.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sign.isEmpty { lines.append("End with this sign-off on its own line, exactly: \(sign)") }
        switch length {
        case .short: lines.append("Keep it as short as it can be.")
        case .asNeeded: break
        }
        switch formality {
        case .casual: lines.append("Write casually, as to someone you know.")
        case .neutral: break
        case .formal: lines.append("Write formally and politely.")
        }
        lines.append(emoji ? "One emoji is fine if it suits." : "Use no emoji.")
        let free = freeLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty { lines.append("The writer's own note about their style: \(free)") }
        return lines
    }

    /// Text the wearer typed into the note — trusted, since it is their own: a time or a number
    /// in their sign-off is not something a model made up.
    var trustedText: [String] { [signOff, freeLine].filter { !$0.isEmpty } }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }
}

// MARK: - Learning from edits

/// One thing an edit did to a draft.
enum StyleEditSignal: String, Codable, CaseIterable, Sendable {
    case cutGreeting
    case addedGreeting
    case cutSignOff
    case changedSignOff
    case shortened
    case lengthened
    case removedEmoji
    case addedEmoji

    /// The signal an edit going the other way gives; seeing it starts this one's count again.
    var opposite: StyleEditSignal? {
        switch self {
        case .cutGreeting: .addedGreeting
        case .addedGreeting: .cutGreeting
        case .shortened: .lengthened
        case .lengthened: .shortened
        case .removedEmoji: .addedEmoji
        case .addedEmoji: .removedEmoji
        case .cutSignOff, .changedSignOff: nil
        }
    }
}

/// Counts, by signal. Never text.
struct StyleEditCounts: Codable, Equatable, Sendable {
    var counts: [StyleEditSignal: Int] = [:]
    /// Edits the learner has looked at.
    var edits = 0

    func count(_ signal: StyleEditSignal) -> Int { counts[signal] ?? 0 }
}

/// A change the learner proposes to the style note.
struct StyleSuggestion: Equatable, Sendable {
    let signal: StyleEditSignal
    /// "You often cut the greeting. Stop adding one?"
    var question: String {
        switch signal {
        case .cutGreeting:
            String(localized: "You often cut the greeting. Stop adding one?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .addedGreeting:
            String(localized: "You often add a greeting. Start drafts with “Hi” and their name?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .cutSignOff:
            String(localized: "You often cut the sign-off. Stop adding one?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .shortened:
            String(localized: "You often shorten drafts. Keep them short?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .lengthened:
            String(localized: "You often add to drafts. Write as much as is needed?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .removedEmoji:
            String(localized: "You often take emoji out. Stop using them?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .addedEmoji:
            String(localized: "You often add emoji. Allow one in drafts?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        case .changedSignOff:
            String(localized: "You often change the sign-off. Stop adding one?",
                   comment: "My Day: a suggested change to the wearer's writing style, learned from their edits.")
        }
    }
}

/// Pure: compares an edit's before and after, keeps counts, proposes a change.
enum StyleEditLearner {
    /// Consistent edits before a suggestion.
    static let threshold = 3
    /// A length change counts when the text moved by at least this share…
    static let lengthShare = 0.2
    /// …and at least this many characters.
    static let lengthMinimum = 15
    /// A line counts as a sign-off when it is at most this many words.
    static let signOffWords = 4

    private static let greetingWords = ["hi", "hello", "hey", "dear", "hiya", "morning", "good morning",
                                        "good afternoon", "good evening", "kia ora", "g'day", "gday"]
    private static let signOffOpeners = ["cheers", "thanks", "thank you", "many thanks", "regards", "kind regards",
                                         "best", "best wishes", "all the best", "see you", "speak soon", "ta",
                                         "warm regards", "talk soon", "love"]

    /// What one edit did.
    static func signals(before: String, after: String) -> Set<StyleEditSignal> {
        var result: Set<StyleEditSignal> = []
        let hadGreeting = hasGreeting(before)
        let hasGreetingNow = hasGreeting(after)
        if hadGreeting && !hasGreetingNow { result.insert(.cutGreeting) }
        if !hadGreeting && hasGreetingNow { result.insert(.addedGreeting) }

        let oldSign = signOff(before)
        let newSign = signOff(after)
        if oldSign != nil && newSign == nil { result.insert(.cutSignOff) }
        if let oldSign, let newSign, oldSign != newSign { result.insert(.changedSignOff) }

        let oldLength = before.trimmingCharacters(in: .whitespacesAndNewlines).count
        let newLength = after.trimmingCharacters(in: .whitespacesAndNewlines).count
        let delta = newLength - oldLength
        if abs(delta) >= lengthMinimum, Double(abs(delta)) >= Double(oldLength) * lengthShare {
            result.insert(delta < 0 ? .shortened : .lengthened)
        }

        let oldEmoji = emojiCount(before)
        let newEmoji = emojiCount(after)
        if newEmoji < oldEmoji { result.insert(.removedEmoji) }
        if newEmoji > oldEmoji { result.insert(.addedEmoji) }
        return result
    }

    /// Fold one edit's signals in: each signal counts up, and its opposite starts again.
    static func record(_ signals: Set<StyleEditSignal>, into counts: StyleEditCounts) -> StyleEditCounts {
        var next = counts
        next.edits += 1
        for signal in signals {
            next.counts[signal, default: 0] += 1
            if let opposite = signal.opposite { next.counts[opposite] = nil }
        }
        return next
    }

    /// The change to propose, if any signal has reached the threshold and the style does not
    /// already say so. Strongest count first, then the order of `StyleEditSignal`.
    static func suggestion(counts: StyleEditCounts, style: WritingStyle) -> StyleSuggestion? {
        let ready = StyleEditSignal.allCases.filter { counts.count($0) >= threshold && wouldChange($0, style) }
        guard let best = ready.max(by: { lhs, rhs in
            let left = counts.count(lhs), right = counts.count(rhs)
            if left != right { return left < right }
            return StyleEditSignal.allCases.firstIndex(of: lhs)! > StyleEditSignal.allCases.firstIndex(of: rhs)!
        }) else { return nil }
        return StyleSuggestion(signal: best)
    }

    /// The style with the suggestion taken.
    static func apply(_ suggestion: StyleSuggestion, to style: WritingStyle) -> WritingStyle {
        var next = style
        switch suggestion.signal {
        case .cutGreeting: next.greeting = .none
        case .addedGreeting: next.greeting = .hiName
        case .cutSignOff, .changedSignOff: next.signOff = ""
        case .shortened: next.length = .short
        case .lengthened: next.length = .asNeeded
        case .removedEmoji: next.emoji = false
        case .addedEmoji: next.emoji = true
        }
        return next
    }

    /// Accepted or ignored: the signal's count starts again either way.
    static func settle(_ suggestion: StyleSuggestion, counts: StyleEditCounts) -> StyleEditCounts {
        var next = counts
        next.counts[suggestion.signal] = nil
        return next
    }

    private static func wouldChange(_ signal: StyleEditSignal, _ style: WritingStyle) -> Bool {
        apply(StyleSuggestion(signal: signal), to: style) != style
            // A changed sign-off says nothing to take unless the note sets one.
            && (signal != .changedSignOff || !style.signOff.isEmpty)
            // Suggest "stop adding a sign-off" only while the note adds one.
            && (signal != .cutSignOff || !style.signOff.isEmpty)
    }

    // MARK: - Reading a draft

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
    }

    static func hasGreeting(_ text: String) -> Bool {
        guard let first = lines(text).first else { return false }
        let lower = normalised(first)
        return greetingWords.contains { word in
            guard lower.hasPrefix(word) else { return false }
            let rest = lower.dropFirst(word.count)
            return rest.isEmpty || rest.first.map { !$0.isLetter } == true
        }
    }

    /// The last line, when it reads as a sign-off: its own line after the body, a few words, and
    /// either a sign-off word or a name.
    static func signOff(_ text: String) -> String? {
        let all = lines(text)
        guard all.count >= 2, let last = all.last else { return nil }
        let words = last.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard !words.isEmpty, words.count <= signOffWords, !last.hasSuffix("?"), !last.hasSuffix(":"),
              !last.hasPrefix("•") else { return nil }
        let lower = normalised(last)
        let opens = signOffOpeners.contains { word in
            guard lower.hasPrefix(word) else { return false }
            let rest = lower.dropFirst(word.count)
            return rest.isEmpty || rest.first.map { !$0.isLetter } == true
        }
        let isName = words.count <= 2 && words.allSatisfy { $0.first?.isUppercase == true }
            && !last.hasSuffix(".")
        return opens || isName ? lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) : nil
    }

    static func emojiCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }.count
    }
}

// MARK: - The store

/// The style note and the learner's counts: one JSON file beside the cards' state,
/// `Application Support/PreparedCards/style.json`. The note is the wearer's own words and can
/// name a person (a sign-off names the wearer), so it is excluded from backup and the subject
/// erasure walk reaches it. Registered in `DataStoreRegistry` as `writingStyle`.
@MainActor
final class WritingStyleStore: ObservableObject {
    static let shared = WritingStyleStore()

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    private static let formatVersion = 1

    private struct File: Codable {
        var version: Int
        var style: WritingStyle
        var counts: StyleEditCounts
    }

    @Published private(set) var style = WritingStyle.standard
    @Published private(set) var counts = StyleEditCounts()
    /// The learner's current proposal, until it is accepted or ignored.
    var suggestion: StyleSuggestion? { StyleEditLearner.suggestion(counts: counts, style: style) }

    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? PreparedCardStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("style.json")
        reload()
    }

    func update(_ change: (inout WritingStyle) -> Void) {
        var next = style
        change(&next)
        guard next != style else { return }
        style = next
        save()
    }

    /// One edit, before and after. Only the counts are kept.
    func learn(before: String, after: String) {
        let signals = StyleEditLearner.signals(before: before, after: after)
        counts = StyleEditLearner.record(signals, into: counts)
        save()
    }

    func accept(_ suggestion: StyleSuggestion) {
        style = StyleEditLearner.apply(suggestion, to: style)
        counts = StyleEditLearner.settle(suggestion, counts: counts)
        save()
    }

    func ignore(_ suggestion: StyleSuggestion) {
        counts = StyleEditLearner.settle(suggestion, counts: counts)
        save()
    }

    // MARK: - Erasure

    func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
        style = .standard
        counts = StyleEditCounts()
    }

    /// For a subject erasure: a sign-off or free line naming `token` is cleared. Returns how many
    /// fields went.
    @discardableResult
    func forget(matching token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        var next = style
        var removed = 0
        if next.signOff.localizedCaseInsensitiveContains(needle) { next.signOff = ""; removed += 1 }
        if next.freeLine.localizedCaseInsensitiveContains(needle) { next.freeLine = ""; removed += 1 }
        guard removed > 0 else { return 0 }
        style = next
        save()
        return removed
    }

    // MARK: - Storage

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? RecordJSONCodec.decoder().decode(File.self, from: data),
              file.version == Self.formatVersion else {
            style = .standard
            counts = StyleEditCounts()
            return
        }
        style = file.style
        counts = file.counts
    }

    private func save() {
        let file = File(version: Self.formatVersion, style: style, counts: counts)
        guard let data = try? RecordJSONCodec.encoder().encode(file) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        StoreProtection.apply(Self.fileProtection, backupExcluded: true, to: fileURL)
    }
}
