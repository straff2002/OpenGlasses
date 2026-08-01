import Foundation

/// Plan BY P1 — pure caption mechanics: the provider-agnostic quality layer under live captions.
/// These harden the *existing* ambient-caption and live-transcript paths today, and are the
/// substrate the translation tiers (P2 cloud, P3 on-device) plug into.

// MARK: - Script-aware joining (the CJK fix)

/// Fixes a live defect: streamed transcription arrives in word-segmented chunks with separator
/// spaces (ASR-style), and every consumer concatenated them naively (`userTranscript += text`),
/// so Chinese rendered as `你手里 拿的 是`. Not a font problem — the spaces are in the string.
///
/// Between Latin words those spaces are correct; between CJK characters they are arbitrary
/// mid-sentence gaps. Collapse whitespace **only** where both neighbours are CJK (or CJK
/// punctuation), so a mixed sentence keeps exactly the spaces that belong there:
/// `你手里拿的是 Hypervolt Go 3 按摩枪`.
enum ScriptAwareJoiner {

    /// Single source for "is this scalar CJK" — `TranscriptGuard` (hallucination filtering) and
    /// this joiner (spacing) both read it, so the script ranges can't drift apart.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch Int(scalar.value) {
        case 0x4E00...0x9FFF,       // CJK unified ideographs
             0x3400...0x4DBF,       // CJK extension A
             0x3040...0x30FF,       // Hiragana / Katakana
             0xAC00...0xD7AF:       // Hangul syllables
            return true
        default:
            return false
        }
    }

    /// CJK punctuation counts as a CJK neighbour: `。`, `、`, `「` etc. carry their own spacing.
    static func isCJKOrPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if isCJK(scalar) { return true }
        switch Int(scalar.value) {
        case 0x3000...0x303F,       // CJK symbols and punctuation
             0xFF00...0xFF65:       // fullwidth forms (！？：… and fullwidth ASCII)
            return true
        default:
            return false
        }
    }

    /// Remove every whitespace run whose immediate neighbours are both CJK. Latin spacing is
    /// provably untouched: a space survives unless BOTH sides are CJK/CJK-punctuation.
    static func collapse(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace {
                // Find the run of whitespace; look at the non-space neighbours.
                var end = index
                while end < scalars.count, scalars[end].properties.isWhitespace { end += 1 }
                let before = out.last
                let after = end < scalars.count ? scalars[end] : nil
                let dropRun = before.map(isCJKOrPunctuation) == true
                    && after.map(isCJKOrPunctuation) == true
                if !dropRun {
                    for i in index..<end { out.append(scalars[i]) }
                }
                index = end
            } else {
                out.append(scalar)
                index += 1
            }
        }
        return String(out)
    }

    /// Append a streamed chunk to an accumulating transcript, collapsing only the seam — cheaper
    /// than re-collapsing the whole transcript per delta, and identical in result because earlier
    /// seams were already handled when their chunks arrived.
    static func join(_ accumulated: String, _ chunk: String) -> String {
        guard !accumulated.isEmpty else { return chunk }
        guard !chunk.isEmpty else { return accumulated }
        // Collapse across the seam: last visible scalar of `accumulated` vs first of `chunk`.
        let seam = String(accumulated.suffix(8)) + String(chunk.prefix(8))
        let joined = accumulated + chunk
        let collapsedSeam = collapse(seam)
        if collapsedSeam == seam { return joined }
        return String(accumulated.dropLast(min(8, accumulated.count)))
            + collapsedSeam
            + String(chunk.dropFirst(min(8, chunk.count)))
    }
}

// MARK: - Endpoint debouncing

/// Kills the mid-sentence caption splits that make live captions feel broken: when the provider
/// signals an utterance endpoint, hold ~500 ms — if more tokens arrive in the hold window, the
/// endpoint was premature and is discarded (the caption keeps accumulating instead of splitting).
///
/// Pure state machine over injected timestamps; the service supplies the clock and the timer.
struct EndpointDebouncer {

    let holdInterval: TimeInterval

    private(set) var pendingSince: Date?

    init(holdInterval: TimeInterval = 0.5) {
        self.holdInterval = holdInterval
    }

    /// The provider signaled an endpoint. Held, not committed.
    mutating func endpointSignaled(now: Date) {
        pendingSince = pendingSince ?? now
    }

    /// Tokens arrived. Returns `true` when this discards a held endpoint — the split was
    /// premature and the caller should treat the new tokens as a continuation.
    @discardableResult
    mutating func tokensArrived(now: Date) -> Bool {
        guard let since = pendingSince else { return false }
        pendingSince = nil
        // Inside the hold window → premature endpoint, discarded. After it, the endpoint should
        // already have been committed by the caller's timer; treat as discarded anyway — the
        // caller committing late loses to the evidence that speech continued.
        _ = since
        return true
    }

    /// Whether a held endpoint has survived the hold window and should commit.
    func shouldCommit(now: Date) -> Bool {
        guard let since = pendingSince else { return false }
        return now.timeIntervalSince(since) >= holdInterval
    }

    /// The caller committed the endpoint (finalized the caption).
    mutating func committed() {
        pendingSince = nil
    }
}

// MARK: - Rolling compaction

/// Rolling compaction for long utterances: finalized text collapses into a stable prefix; only
/// the unstable tail stays revisable. The rendered interim is `prefix + tail`, and **the final
/// always equals the last interim** — no jarring rewrite at commit, by construction: `finalize()`
/// returns the same string `rendered` last produced.
///
/// Stability rule: once promoted, prefix text never changes even if the recognizer revises early
/// words in a later interim — for a *display* surface, stability beats late accuracy.
struct CaptionCompactor {

    /// Tail longer than this promotes its head into the prefix (keeping the last
    /// `revisableSuffixLength` characters revisable).
    let promoteThreshold: Int
    /// How much recent text stays revisable when promotion happens.
    let revisableSuffixLength: Int
    /// Cap on the rendered string — a monologue drops its oldest prefix text (with an ellipsis)
    /// rather than growing without bound.
    let maxRendered: Int

    private(set) var stablePrefix: String = ""
    private(set) var tail: String = ""

    init(promoteThreshold: Int = 120, revisableSuffixLength: Int = 40, maxRendered: Int = 2_000) {
        self.promoteThreshold = promoteThreshold
        self.revisableSuffixLength = revisableSuffixLength
        self.maxRendered = maxRendered
    }

    /// Script-aware at every seam: continuation joins can put CJK beside CJK, and collapse is
    /// idempotent on already-clean text, so rendering collapses unconditionally.
    var rendered: String { ScriptAwareJoiner.collapse(stablePrefix + tail) }

    /// Full-text interim for the current *segment* (SFSpeech style: each result replaces the
    /// whole utterance-so-far of this recognition session). The prefix — text committed by
    /// earlier segments via `beginContinuation` — is untouched: stability beats late revision.
    mutating func acceptSegmentInterim(_ fullText: String) {
        tail = fullText
    }

    /// Delta interim (streamed chunk providers). Long tails promote their head into the prefix so
    /// only the recent text stays revisable. The size cap is enforced on EVERY delta, not just on
    /// promotion — trimming only at promotion let the rendered text drift ~25% past `maxRendered`
    /// between promotions (caught by the bounded-monologue test, not by review).
    mutating func acceptDelta(_ chunk: String) {
        tail = ScriptAwareJoiner.join(tail, chunk)
        if tail.count > promoteThreshold {
            let cut = tail.index(tail.endIndex, offsetBy: -revisableSuffixLength)
            stablePrefix += tail[..<cut]
            tail = String(tail[cut...])
        }
        trimIfNeeded()
    }

    /// A premature endpoint was discarded: the segment that just "ended" is actually mid-sentence.
    /// Commit its text into the prefix and continue accumulating — the caption entry does not
    /// split (the whole point of the debouncer).
    mutating func beginContinuation() {
        guard !tail.isEmpty else { return }
        stablePrefix = stablePrefix.isEmpty ? tail + " " : stablePrefix + tail + " "
        tail = ""
        trimIfNeeded()
    }

    /// Commit the utterance. Returns exactly the last rendered interim.
    mutating func finalize() -> String {
        let final = rendered
        stablePrefix = ""
        tail = ""
        return final
    }

    private mutating func trimIfNeeded() {
        if stablePrefix.count + tail.count > maxRendered {
            let overflow = stablePrefix.count + tail.count - maxRendered
            if overflow < stablePrefix.count {
                stablePrefix = "…" + stablePrefix.dropFirst(overflow + 1)
            }
        }
    }
}

// MARK: - Translation seam (P2/P3 plug points)

/// One unit of translated (or plain) caption text from a provider.
struct TranslationSegment: Equatable {
    let text: String
    let isFinal: Bool
    /// Diarized speaker index; nil on single-speaker paths.
    let speaker: Int?
    /// BCP-47 of the *detected source* language, when the provider reports it.
    let language: String?
    /// Source-language transcript this segment translates (the show-original ribbon), when the
    /// provider captured one.
    let original: String?

    init(text: String, isFinal: Bool, speaker: Int? = nil, language: String? = nil,
         original: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.language = language
        self.original = original
    }
}

/// Which direction(s) a session translates.
enum TranslationDirectionPolicy: Equatable {
    /// Everything renders in `target`.
    case oneWay(target: String)
    /// Two legs: each final segment renders in the *counterpart* of its detected language.
    case twoWay(String, String)

    /// The language a segment detected as `detected` should render in, or nil when the segment
    /// is already addressed to everyone (one-way) or undetectable.
    func renderLanguage(forDetected detected: String?) -> String? {
        switch self {
        case .oneWay(let target):
            return target
        case .twoWay(let a, let b):
            guard let detected else { return nil }
            if detected.hasPrefix(a) { return b }
            if detected.hasPrefix(b) { return a }
            return nil
        }
    }
}

/// What a caption/translation source must provide. The existing ambient path and both future
/// tiers (cloud unified STT+translation, on-device SenseVoice → Apple Translation) conform.
@MainActor
protocol TranslationCaptionProvider: AnyObject {
    var onSegment: ((TranslationSegment) -> Void)? { get set }
    func start(direction: TranslationDirectionPolicy) throws
    func stop()
}

// MARK: - Formatting

/// Speaker labels and line shaping for caption surfaces.
enum TranslationCaptionFormatter {

    /// `[2]:` prefix only when the diarized speaker *changes* — stable across interim→final, so
    /// the label never flickers on revision.
    static func line(text: String, speaker: Int?, previousSpeaker: Int?) -> String {
        guard let speaker, speaker != previousSpeaker else { return text }
        return "[\(speaker + 1)]: \(text)"
    }

    /// Tail-biased wrap for a fixed caption window: keeps the *most recent* lines when the text
    /// overflows, which is what a live caption surface wants (the past scrolls away).
    static func windowLines(_ text: String, maxCharsPerLine: Int, maxLines: Int) -> [String] {
        guard maxCharsPerLine > 0, maxLines > 0 else { return [] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= maxCharsPerLine {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                // A single overlong word (or unspaced CJK run) hard-wraps.
                var chunk = String(word)
                while chunk.count > maxCharsPerLine {
                    lines.append(String(chunk.prefix(maxCharsPerLine)))
                    chunk = String(chunk.dropFirst(maxCharsPerLine))
                }
                current = chunk
            }
        }
        if !current.isEmpty { lines.append(current) }
        return Array(lines.suffix(maxLines))
    }
}
