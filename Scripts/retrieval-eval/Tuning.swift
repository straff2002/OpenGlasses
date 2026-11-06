import Foundation
import NaturalLanguage

// Plan JY P3: candidate values for the language groups' term rules, read from the environment by
// the Mac runner only. The app's sources consult this under `#if RETRIEVAL_EVAL`, which run.sh
// alone defines, so nothing here reaches a shipped build; every value left unset is the shipped
// one.
//
//   RETRIEVAL_EVAL_PREFIX="6" or "cyrillic=5,latinHeavy=7"   letters a prefix stem keeps
//   RETRIEVAL_EVAL_MINLEN="3" or "cjk=…,urdu=2"               the shortest word kept
//   RETRIEVAL_EVAL_ENDINGS="1" or "cyrillic=1"                strip one ending before the prefix
//   RETRIEVAL_EVAL_FOLD=1                                     fold ё/ї/ґ in Cyrillic words
//   RETRIEVAL_EVAL_CJK=words                                  NLTokenizer words instead of bigrams
//   RETRIEVAL_EVAL_GATE_GROUP="cjk=3,0.6;cyrillic=2,0.5"      a group's lexical criterion
//   RETRIEVAL_EVAL_PENDING="0.25" or "cjk=0.25,arabic=0.1"    the stricter share for a pending passage
enum RetrievalEvalTuning {
    private static let env = ProcessInfo.processInfo.environment

    /// "6" (every group but English) or "group=value,…".
    static func perGroup<T>(_ name: String, _ parse: (String) -> T?) -> [TermRule.Group: T] {
        guard let raw = env[name], !raw.isEmpty else { return [:] }
        var out: [TermRule.Group: T] = [:]
        if let all = parse(raw) {
            for group in TermRule.Group.allCases where group != .english { out[group] = all }
            return out
        }
        for part in raw.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let group = TermRule.Group(rawValue: pair[0]), let value = parse(pair[1]) else {
                fatalError("\(name): can't read \(part)")
            }
            out[group] = value
        }
        return out
    }

    private static let prefixes = perGroup("RETRIEVAL_EVAL_PREFIX") { Int($0) }
    private static let minimums = perGroup("RETRIEVAL_EVAL_MINLEN") { Int($0) }
    /// Plan KO: RETRIEVAL_EVAL_CODE_LEAD="<places>" or "off" (the order before the code lead).
    static let codeLeadPlaces: Int? = env["RETRIEVAL_EVAL_CODE_LEAD"].map { raw in
        if raw == "off" { return .max }
        guard let places = Int(raw), places >= 0 else { fatalError("RETRIEVAL_EVAL_CODE_LEAD is a number or off") }
        return places
    }

    /// A switch read as "1" or "0"; nil when unset.
    static func flag(_ name: String) -> Bool? { env[name].map { $0 == "1" } }

    private static let endings = perGroup("RETRIEVAL_EVAL_ENDINGS") { ["1": true, "0": false][$0] }
    static func stripsEndings(_ group: TermRule.Group) -> Bool? { endings[group] }
    static func prefixLength(_ group: TermRule.Group) -> Int? { prefixes[group] }
    static func minimumLength(_ group: TermRule.Group) -> Int? { minimums[group] }

    /// The pending-passage increase per group, for the policy.
    static let pendingIncrease = perGroup("RETRIEVAL_EVAL_PENDING") { Double($0) }

    /// "group=terms,fraction;…" for the policy.
    static let groupCriteria: [TermRule.Group: RetrievalEvidencePolicy.LexicalCriterion] = {
        guard let raw = env["RETRIEVAL_EVAL_GATE_GROUP"], !raw.isEmpty else { return [:] }
        var out: [TermRule.Group: RetrievalEvidencePolicy.LexicalCriterion] = [:]
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            let values = pair.count == 2 ? pair[1].split(separator: ",").map(String.init) : []
            guard pair.count == 2, let group = TermRule.Group(rawValue: pair[0]), values.count == 2,
                  let terms = Int(values[0]), let fraction = Double(values[1]) else {
                fatalError("RETRIEVAL_EVAL_GATE_GROUP: can't read \(part)")
            }
            out[group] = .init(minSharedTerms: terms, sharedFraction: fraction)
        }
        return out
    }()

    // MARK: - Plan JY P4: chunk sizes and the structure rules, measured one at a time

    /// RETRIEVAL_EVAL_CHUNK_SCALE="cjk=0.6" or "zh-Hans=0.8,ja=1.3,cyrillic=1.5": a document's
    /// character targets scaled, keyed by its language or by "cjk", "cyrillic", "arabic".
    private static let chunkScales: [String: Double] = {
        guard let raw = env["RETRIEVAL_EVAL_CHUNK_SCALE"], !raw.isEmpty else { return [:] }
        var out: [String: Double] = [:]
        for part in raw.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let value = Double(pair[1]) else { fatalError("RETRIEVAL_EVAL_CHUNK_SCALE: can't read \(part)") }
            out[pair[0]] = value
        }
        return out
    }()

    static func chunkScale(script: TextScript, language: String?) -> Double? {
        if let language, let value = chunkScales[language] { return value }
        switch script {
        case .han, .kana, .hangul: return chunkScales["cjk"]
        case .cyrillic: return chunkScales["cyrillic"]
        case .arabic: return chunkScales["arabic"]
        default: return nil
        }
    }

    /// RETRIEVAL_EVAL_P4_OFF="captions,split,clauses": a P4 rule switched off, to measure it.
    static let p4Off = Set((env["RETRIEVAL_EVAL_P4_OFF"] ?? "").split(separator: ",").map(String.init))

    /// RETRIEVAL_EVAL_P5="majority" | "nomajority" | "split", joined with ",": a Plan JY P5a
    /// candidate switched on, to measure it — every language's chunks credited to the page that
    /// holds most of them (or none's), a chunk split at every page break.
    static let p5 = Set((env["RETRIEVAL_EVAL_P5"] ?? "").split(separator: ",").map(String.init))
    /// RETRIEVAL_EVAL_MAJORITY="0.67": the share of a chunk's characters its page must hold for
    /// `majority` to credit it there (0, the default: the page holding the most).
    static let majorityShare = Double(env["RETRIEVAL_EVAL_MAJORITY"] ?? "") ?? 0

    // MARK: - CJK words (decision 2's alternative, measured, not shipped)

    private static let wordsWanted = env["RETRIEVAL_EVAL_CJK"] == "words"
    private static let cjkVariants = Set((env["RETRIEVAL_EVAL_CJK"] ?? "").split(separator: "+").map(String.init))
    /// "kana", "kopart": the bigram variants (RETRIEVAL_EVAL_CJK=kana+kopart, "none" for neither);
    /// nil when unset, which keeps the shipped ones.
    static func cjkVariant(_ name: String) -> Bool? { env["RETRIEVAL_EVAL_CJK"] == nil ? nil : cjkVariants.contains(name) }
    nonisolated(unsafe) private static var cache: [String: [String]] = [:]
    private static let lock = NSLock()

    /// A Han, kana or Hangul run cut into `NLTokenizer` words instead of bigrams, the particles
    /// left out, when RETRIEVAL_EVAL_CJK=words; nil otherwise.
    static func cjkWords(_ run: String) -> [String]? {
        guard wordsWanted else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let known = cache[run] { return known }
        let tokenizer = NLTokenizer(unit: .word)
        let language: NLLanguage = run.unicodeScalars.contains { TextScript.of($0) == .kana } ? .japanese
            : run.unicodeScalars.contains { TextScript.of($0) == .hangul } ? .korean : .simplifiedChinese
        tokenizer.setLanguage(language)
        tokenizer.string = run
        var words: [String] = []
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            let word = String(run[range])
            if !TermRuleStopwords.singleCharacters.contains(word), !TermRuleStopwords.bigrams.contains(word) {
                words.append(word)
            }
            return true
        }
        cache[run] = words
        return words
    }
}
