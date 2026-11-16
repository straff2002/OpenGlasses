import CryptoKit
import Foundation

/// What a chart reading's cache keeps, and under what key (Plan LX §9, decision 7 taken
/// 2026-11-16: image and prompt only, the model recorded). The decision only: the cache on disk,
/// its folder beside `PictureTableCheckpoint`'s, its erasure with the manual and its registration
/// come with the reading itself (P1). Pure.
enum ChartCachePolicy {

    /// Exactly what a reading was asked with. Any change to one of these is a different question.
    struct Prompt: Equatable {
        var system: String
        var user: String
        var schema: String
        var version: Int
    }

    /// SHA-256 of the exact image bytes sent, joined with SHA-256 of the exact prompt. The model is
    /// not in it, so switching models does not pay again; `Entry.modelId` says which one read it.
    struct Key: Hashable, Codable {
        let imageHash: String
        let promptHash: String

        var string: String { imageHash + ":" + promptHash }
    }

    static func key(image: Data, prompt: Prompt) -> Key {
        Key(imageHash: sha256(image), promptHash: promptHash(prompt))
    }

    static func promptHash(_ prompt: Prompt) -> String {
        // A unit separator between the parts, so moving text from one part to the next changes it.
        let joined = [prompt.system, prompt.user, prompt.schema, String(prompt.version)].joined(separator: "\u{1F}")
        return sha256(Data(joined.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// How a reading request came back.
    enum Reply: Equatable {
        /// A whole reply the schema decoder accepted, and what the validator made of it.
        case complete(ChartReading, verdict: Verdict)
        /// Cut off at its token limit: the provider said so, or the JSON does not close.
        case cutOff
        /// The request failed.
        case failed
        /// A whole reply the schema decoder refused.
        case undecodable
    }

    /// The validator's verdict as stored: a usable reading, words only, or rejected.
    enum Verdict: String, Codable, Equatable {
        case usable
        case wordsOnly = "words_only"
        case rejected

        init(_ verdict: ChartReadingValidator.Verdict) {
            switch verdict {
            case .usable: self = .usable
            case .wordsOnly: self = .wordsOnly
            case .rejected: self = .rejected
            }
        }
    }

    struct Entry: Equatable, Codable {
        let key: Key
        let reading: ChartReading
        let verdict: Verdict
        let modelId: String
        let date: Date
    }

    enum Decision: Equatable {
        /// Keep it. A rejected reading is kept too, as rejected, so the same misread is not paid
        /// for again; **Read again** replaces it.
        case store(Entry)
        /// Keep nothing; ask again on the next question, at most once a day for this chart.
        case retryLater
    }

    /// The least time between two attempts at a chart whose reading was not stored.
    static let retryInterval: TimeInterval = 24 * 60 * 60

    static func decide(_ reply: Reply, key: Key, modelId: String, date: Date) -> Decision {
        switch reply {
        case .complete(let reading, let verdict):
            return .store(Entry(key: key, reading: reading, verdict: verdict, modelId: modelId, date: date))
        case .cutOff, .failed, .undecodable:
            return .retryLater
        }
    }

    /// The stored entry for a key: the same image and prompt hit, whichever model read it.
    static func lookup(_ key: Key, in entries: [Entry]) -> Entry? {
        entries.last { $0.key == key }
    }

    /// Whether a chart whose last attempt stored nothing may be asked again now.
    static func mayRetry(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= retryInterval
    }

    /// The entries with `entry` in place of any for its key: **Read again** replaces a reading.
    static func replacing(_ entries: [Entry], with entry: Entry) -> [Entry] {
        entries.filter { $0.key != entry.key } + [entry]
    }
}
