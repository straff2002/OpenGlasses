import Foundation

/// Greedy CTC decoding for the fingerspelling model's logit rows (Plan CK P2).
///
/// The model emits `(768/2, 62)` logits: class 0 is the CTC blank, classes 1–59 map to the
/// 59-character training charset (ids − 1), and the two trailing classes are auxiliary
/// begin/end tokens that decoding ignores. Only the first ⌈T/2⌉ rows correspond to real
/// input frames — callers slice before decoding. Pure; fixture tests hold `decode` to the
/// Python reference bit-for-bit.
enum FingerspellingCTCDecoder {

    /// The training charset, indexed by class id − 1. Fixed by the model — shipped in code
    /// rather than parsed from a sidecar so decoding cannot drift from the training
    /// contract; `vocabulary(fromSidecar:)` exists to sanity-check a downloaded copy.
    static let charset: [Character] = Array(" !#$%&'()*+,-./0123456789:;=?@[_abcdefghijklmnopqrstuvwxyz~")

    /// The CTC blank class id.
    static let blankClass = 0

    /// Parse a `vocab.txt` sidecar (first line the literal `<blank>`, then one character
    /// per line — a space line is significant, so no trimming). Returns nil when malformed;
    /// callers compare against `charset` to detect a stale artefact.
    static func vocabulary(fromSidecar text: String) -> [Character]? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() } // allow a trailing newline
        guard lines.first == "<blank>" else { return nil }
        let symbols = lines.dropFirst()
        guard !symbols.isEmpty, symbols.allSatisfy({ $0.count == 1 }) else { return nil }
        return symbols.map { $0.first! }
    }

    /// One logit row reduced to the policy's observation shape: the argmax class as a
    /// character (nil for blank or an out-of-charset auxiliary class) plus its softmax
    /// probability.
    static func observation(forRow row: [Float]) -> (letter: Character?, confidence: Double) {
        guard let maxLogit = row.max(), let argmax = row.firstIndex(of: maxLogit) else {
            return (nil, 0)
        }
        // Numerically stable softmax probability of the winning class.
        var denominator = 0.0
        for value in row { denominator += exp(Double(value - maxLogit)) }
        let confidence = 1.0 / denominator

        let symbolIndex = argmax - 1
        guard argmax != blankClass, charset.indices.contains(symbolIndex) else {
            return (nil, confidence)
        }
        return (charset[symbolIndex], confidence)
    }

    /// Greedy CTC decode: per-row argmax, collapse adjacent repeats, drop blanks, map the
    /// surviving ids through the charset (auxiliary classes are dropped).
    static func decode(logitRows: [[Float]]) -> String {
        var decoded = ""
        var previousClass = -1
        for row in logitRows {
            guard let maxLogit = row.max(), let argmax = row.firstIndex(of: maxLogit) else {
                continue
            }
            defer { previousClass = argmax }
            guard argmax != previousClass, argmax != blankClass else { continue }
            let symbolIndex = argmax - 1
            guard charset.indices.contains(symbolIndex) else { continue }
            decoded.append(charset[symbolIndex])
        }
        return decoded
    }
}
