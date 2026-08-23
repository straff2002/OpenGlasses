import Foundation

/// One chat line ready to be spoken — the policy's only output. The policy never touches TTS.
struct SpokenChatItem: Equatable {
    /// Who wrote it (display name).
    let user: String
    /// TTS-ready rendering, e.g. `"Sam says: great view"` / `"And: where is this?"`.
    let text: String
    /// Whether it mentioned the streamer's handle (jumped the queue).
    let isMention: Bool
}

/// Tunables for `ChatReadbackPolicy` — plain data so tests (and Settings) drive them directly.
struct ChatReadbackRules: Equatable {
    /// Max messages spoken per rolling minute.
    var rateCapPerMinute: Int = 6
    /// Max messages waiting to be spoken; beyond it the oldest non-mention drops.
    var queueCap: Int = 5
    /// Window in which an identical text is not spoken twice (seconds).
    var dedupWindow: TimeInterval = 30
    /// Consecutive messages from the same user inside this window skip the name (seconds).
    var burstWindow: TimeInterval = 20
    /// Spoken text is truncated to this many characters.
    var maxSpokenLength: Int = 200
    /// Speak only messages that mention `streamerHandle`.
    var mentionsOnly: Bool = false
    /// The streamer's handle for mention detection (matched with or without `@`, any case).
    var streamerHandle: String = ""

    /// The subset the shared `AmbientSpeechArbiter` owns. The remaining fields above are chat
    /// taste (burst rendering, length cap, mention matching) and stay here.
    var arbitration: AmbientSpeechRules {
        AmbientSpeechRules(rateCapPerMinute: rateCapPerMinute,
                           queueCap: queueCap,
                           dedupWindow: dedupWindow)
    }
}

/// The taste layer of broadcast chat readback (Plan CI): decides which chat messages get spoken
/// and how they're rendered, as a pure value type — inputs are messages, the clock, and the
/// TTS-busy / realtime-session flags; output is `SpokenChatItem`s pulled by the caller.
///
/// Rules (each tested as data): commands and bot prefixes skipped; URLs stripped; emote-only
/// messages dropped; identical text within the dedup window reads once with a "times N" suffix;
/// a rolling per-minute rate cap with a drop-oldest bounded queue; mentions of the streamer
/// jump the queue; names are spoken once per burst ("Sam says: great view" … "And: where is
/// this?"); nothing is spoken while TTS is busy; while a realtime session is live, readback is
/// suppressed entirely (the queue flushes — two voices in the ear is chaos).
///
/// The rate cap, bounded queue, dedup window, TTS-busy hold and realtime suppression moved into
/// `AmbientSpeechArbiter` (Plan CV P1) so continuous scene narration shares one arbiter rather
/// than growing a second copy of them. Everything above the arbiter — filters, normalisation,
/// mention detection, "times N", burst rendering — is chat-specific and stayed here.
struct ChatReadbackPolicy {

    var rules: ChatReadbackRules {
        didSet { arbiter.rules = rules.arbitration }
    }

    /// What the arbiter hands back when a message finally gets the floor.
    private struct Line: Equatable {
        let user: String
        /// Normalised, TTS-safe text — also the arbiter's dedup key.
        let text: String
        let isMention: Bool
    }

    /// A queued message awaiting speech. `duplicates` counts identical texts merged into it.
    struct PendingItem: Equatable {
        let user: String
        let text: String        // normalised, TTS-safe
        var duplicates: Int
        let isMention: Bool
        let queuedAt: TimeInterval
    }

    private var arbiter: AmbientSpeechArbiter<Line>
    private var lastSpoken: (user: String, at: TimeInterval)?

    /// The pending queue, projected back into chat terms.
    var queue: [PendingItem] {
        arbiter.queue.map {
            PendingItem(user: $0.payload.user, text: $0.payload.text, duplicates: $0.duplicates,
                        isMention: $0.payload.isMention, queuedAt: $0.queuedAt)
        }
    }

    init(rules: ChatReadbackRules = ChatReadbackRules()) {
        self.rules = rules
        self.arbiter = AmbientSpeechArbiter(rules: rules.arbitration)
    }

    // MARK: - Ingest

    /// Consider a parsed message for the spoken queue. Returns whether it was queued (or merged
    /// into a queued duplicate) — false means it was filtered out.
    @discardableResult
    mutating func ingest(_ message: ChatMessage, at now: TimeInterval,
                         realtimeSessionActive: Bool = false) -> Bool {
        // Emote-only messages have nothing worth speaking.
        guard !message.textWithoutEmotes.isEmpty else { return false }

        // Bot/command traffic ("!so", "!uptime") is for the channel's bots, not the ear.
        guard !message.textWithoutEmotes.hasPrefix("!") else { return false }

        let text = Self.normalise(message.textWithoutEmotes, maxLength: rules.maxSpokenLength)
        guard !text.isEmpty else { return false }   // URL-only message

        let isMention = Self.mentions(handle: rules.streamerHandle, in: message.text)
        if rules.mentionsOnly && !isMention { return false }

        // Realtime session live → the arbiter suppresses entirely: nothing accumulates for later.
        let line = Line(user: message.user, text: text, isMention: isMention)
        return arbiter.enqueue(line, dedupKey: text, isPriority: isMention, at: now,
                               suppressed: realtimeSessionActive).isAccepted
    }

    // MARK: - Drain

    /// Pull the next item to speak, if the moment allows one. Call repeatedly (a pump); returns
    /// `nil` while TTS is busy, the rate cap is spent, or nothing is queued.
    mutating func nextItem(at now: TimeInterval, ttsBusy: Bool,
                           realtimeSessionActive: Bool) -> SpokenChatItem? {
        guard let item = arbiter.next(at: now, ttsBusy: ttsBusy,
                                      suppressed: realtimeSessionActive) else { return nil }

        var body = item.payload.text
        if item.duplicates > 1 { body += " — times \(item.duplicates)" }

        // Names once per burst: consecutive items by the same user inside the burst window
        // render as a continuation.
        let user = item.payload.user
        let rendered: String
        if let last = lastSpoken, last.user == user, now - last.at <= rules.burstWindow {
            rendered = "And: \(body)"
        } else {
            rendered = "\(user) says: \(body)"
        }

        lastSpoken = (user: user, at: now)
        return SpokenChatItem(user: user, text: rendered, isMention: item.payload.isMention)
    }

    /// Drop all pending state (call when a broadcast ends).
    mutating func reset() {
        arbiter.reset()
        lastSpoken = nil
    }

    // MARK: - Pieces (internal for tests)

    /// Strip URLs, collapse the leftover whitespace, and cap length for speech.
    static func normalise(_ text: String, maxLength: Int) -> String {
        var out = text
        for pattern in [#"https?://\S+"#, #"\bwww\.\S+"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if out.count > maxLength { out = String(out.prefix(maxLength)) }
        return out
    }

    /// Whether `text` mentions the streamer's handle (`@handle` or the bare handle, any case).
    static func mentions(handle: String, in text: String) -> Bool {
        let handle = handle.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !handle.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        return text.range(of: "(^|\\W)@?\(escaped)($|\\W)",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }
}
