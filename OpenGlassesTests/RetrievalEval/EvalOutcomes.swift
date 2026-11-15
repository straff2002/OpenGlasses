import CryptoKit
import Foundation

/// One scored question's outcome, as a run's outcomes file keeps it, so a later run can be paired
/// with it question by question (`EvalIntervals.pairedBootstrap`).
///
/// **Never the question's text**: a line is the question's place among the key's questions, a
/// short SHA-256 prefix of its text (to recognise the same question in another run, even when the
/// key's lines were reordered or added to), and numbers. Like an index folder, an outcomes file is
/// per-question results and stays outside every repository.
///
/// A line is flat JSON, keys sorted: `{"h":"3f9a…","hit1":1,"hit4":1,"q":7,"rr":0.5}`. A metric
/// that does not apply to a question (a table question that expects no single cell) is left out.
struct EvalOutcome: Codable, Equatable {
    /// The question's 1-based place among the key's questions.
    let q: Int
    /// The first `EvalOutcomes.hashLength` hex digits of SHA-256 of the question's identity.
    let h: String
    var metrics: [String: Double]

    init(q: Int, h: String, metrics: [String: Double]) {
        self.q = q
        self.h = h
        self.metrics = metrics
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        q = try c.decode(Int.self, forKey: Key("q"))
        h = try c.decode(String.self, forKey: Key("h"))
        var metrics: [String: Double] = [:]
        for key in c.allKeys where key.stringValue != "q" && key.stringValue != "h" {
            if let value = try? c.decode(Double.self, forKey: key) { metrics[key.stringValue] = value }
        }
        self.metrics = metrics
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(q, forKey: Key("q"))
        try c.encode(h, forKey: Key("h"))
        for (name, value) in metrics { try c.encode(value, forKey: Key(name)) }
    }
}

enum EvalOutcomes {

    /// Hex digits kept of a question's hash: 64 bits, enough that two questions of one key never
    /// collide, too few to be worth anything but recognising the same question again.
    static let hashLength = 16

    /// Below this share of questions found in both runs, `pair` refuses: the key changed too much
    /// for the two runs to be measuring the same thing.
    static let minimumPairedShare = 0.8

    /// The short hash of a question's identity (its text, trimmed of surrounding spaces; for a
    /// table question its fields joined). Any edit to a question makes it a new question.
    static func hash(_ identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(hashLength))
    }

    // MARK: - The file

    static func encoded(_ outcomes: [EvalOutcome]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try outcomes.map { String(decoding: try encoder.encode($0), as: UTF8.self) + "\n" }.joined()
    }

    /// Reads an outcomes file's lines. Blank lines are skipped; any other unreadable line fails the
    /// read, since a half-read baseline would pair the wrong questions.
    static func decode(_ text: String) throws -> [EvalOutcome] {
        try text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return try JSONDecoder().decode(EvalOutcome.self, from: Data(trimmed.utf8))
        }
    }

    static func write(_ outcomes: [EvalOutcome], to url: URL) throws {
        try encoded(outcomes).write(to: url, atomically: true, encoding: .utf8)
    }

    static func read(from url: URL) throws -> [EvalOutcome] {
        try decode(String(contentsOf: url, encoding: .utf8))
    }

    /// Whether `folder` (links resolved) is inside a git working tree: an outcomes file is
    /// per-question results, and those never go in a repository.
    static func isInsideGitWorkingTree(_ folder: URL) -> Bool {
        var ancestor = folder.standardizedFileURL.resolvingSymlinksInPath()
        while ancestor.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { return true }
            ancestor.deleteLastPathComponent()
        }
        return false
    }

    // MARK: - Pairing two runs

    struct Pairing {
        /// (baseline, current) for every question found in both runs.
        let pairs: [(baseline: EvalOutcome, current: EvalOutcome)]
        let baselineCount: Int
        let currentCount: Int

        var paired: Int { pairs.count }
        var unmatchedBaseline: Int { baselineCount - paired }
        var unmatchedCurrent: Int { currentCount - paired }
        /// Paired questions over the larger run's: both runs must mostly be the same questions.
        var share: Double {
            let larger = max(baselineCount, currentCount)
            return larger == 0 ? 0 : Double(paired) / Double(larger)
        }
        var isComparable: Bool { paired > 0 && share >= EvalOutcomes.minimumPairedShare }

        /// The paired difference of one metric (current − baseline), over the pairs where both runs
        /// have it. `nil` when none do.
        func difference(_ metric: String, resamples: Int = EvalIntervals.defaultResamples,
                        confidence: Double = EvalIntervals.defaultConfidence,
                        seed: UInt64 = EvalIntervals.defaultSeed) -> EvalIntervals.Difference? {
            let both = pairs.compactMap { pair -> (Double, Double)? in
                guard let a = pair.baseline.metrics[metric], let b = pair.current.metrics[metric] else { return nil }
                return (a, b)
            }
            return try? EvalIntervals.pairedBootstrap(a: both.map(\.0), b: both.map(\.1), resamples: resamples,
                                                     confidence: confidence, seed: seed)
        }
    }

    /// Pairs two runs' questions by hash. A question asked twice in one key pairs with the same
    /// occurrence in the other (its first with the other's first, and so on); the question's place
    /// in the key is not used, so reordering or adding questions doesn't break the pairing.
    static func pair(baseline: [EvalOutcome], current: [EvalOutcome]) -> Pairing {
        func keyed(_ outcomes: [EvalOutcome]) -> [(key: String, outcome: EvalOutcome)] {
            var seen: [String: Int] = [:]
            return outcomes.map { outcome in
                let n = seen[outcome.h, default: 0]
                seen[outcome.h] = n + 1
                return (outcome.h + "#\(n)", outcome)
            }
        }
        let base = Dictionary(keyed(baseline).map { ($0.key, $0.outcome) }, uniquingKeysWith: { first, _ in first })
        let pairs = keyed(current).compactMap { entry in base[entry.key].map { (baseline: $0, current: entry.outcome) } }
        return Pairing(pairs: pairs, baselineCount: baseline.count, currentCount: current.count)
    }

    /// The comparison with a baseline as lines, counts and rates only:
    /// `<prefix> vs baseline: paired 70 of 72 (unmatched: 2 here, 0 in the baseline)` then one
    /// difference per metric, or why the runs can't be compared.
    static func comparisonLines(prefix: String, pairing: Pairing, metrics: [(name: String, key: String)],
                                resamples: Int = EvalIntervals.defaultResamples,
                                confidence: Double = EvalIntervals.defaultConfidence) -> [String] {
        let counts = "paired \(pairing.paired) of \(max(pairing.baselineCount, pairing.currentCount)) "
            + "(unmatched: \(pairing.unmatchedCurrent) here, \(pairing.unmatchedBaseline) in the baseline)"
        guard pairing.isComparable else {
            return ["\(prefix) vs baseline: not compared, \(counts): under \(Int(minimumPairedShare * 100))% of the "
                    + "questions are in both runs, so the answer key changed too much"]
        }
        let parts = metrics.compactMap { metric -> String? in
            pairing.difference(metric.key, resamples: resamples, confidence: confidence).map { d in
                "\(metric.name) \(d.formatted)" + (d.interval.count == pairing.paired ? "" : " (n=\(d.interval.count))")
            }
        }
        return ["\(prefix) vs baseline: \(counts)",
                "\(prefix) vs baseline, change \(Int((confidence * 100).rounded()))% paired interval: "
                    + (parts.isEmpty ? "no metric in both runs" : parts.joined(separator: " · "))]
    }
}
