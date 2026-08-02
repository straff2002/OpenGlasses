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
struct ChatReadbackPolicy {

    var rules: ChatReadbackRules

    /// A queued message awaiting speech. `duplicates` counts identical texts merged into it.
    struct PendingItem: Equatable {
        let user: String
        let text: String        // normalised, TTS-safe
        var duplicates: Int
        let isMention: Bool
        let queuedAt: TimeInterval
    }

    private(set) var queue: [PendingItem] = []
    private var spokenAt: [TimeInterval] = []                       // rolling rate-cap window
    private var recentlySpoken: [(text: String, at: TimeInterval)] = []
    private var lastSpoken: (user: String, at: TimeInterval)?

    init(rules: ChatReadbackRules = ChatReadbackRules()) {
        self.rules = rules
    }

    // MARK: - Ingest

    /// Consider a parsed message for the spoken queue. Returns whether it was queued (or merged
    /// into a queued duplicate) — false means it was filtered out.
    @discardableResult
    mutating func ingest(_ message: ChatMessage, at now: TimeInterval,
                         realtimeSessionActive: Bool = false) -> Bool {
        // Realtime session live → suppressed entirely: nothing accumulates for later.
        guard !realtimeSessionActive else { return false }

        // Emote-only messages have nothing worth speaking.
        guard !message.textWithoutEmotes.isEmpty else { return false }

        // Bot/command traffic ("!so", "!uptime") is for the channel's bots, not the ear.
        guard !message.textWithoutEmotes.hasPrefix("!") else { return false }

        let text = Self.normalise(message.textWithoutEmotes, maxLength: rules.maxSpokenLength)
        guard !text.isEmpty else { return false }   // URL-only message

        let isMention = Self.mentions(handle: rules.streamerHandle, in: message.text)
        if rules.mentionsOnly && !isMention { return false }

        // Identical text already waiting → merge ("times N"), don't queue again.
        if let i = queue.firstIndex(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            queue[i].duplicates += 1
            return true
        }
        // Identical text spoken within the dedup window → already read once, drop.
        recentlySpoken.removeAll { now - $0.at > rules.dedupWindow }
        if recentlySpoken.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return false
        }

        let item = PendingItem(user: message.user, text: text, duplicates: 1,
                               isMention: isMention, queuedAt: now)
        if isMention {
            // Jump the queue: behind any earlier mentions, ahead of everything else.
            let insertAt = queue.firstIndex(where: { !$0.isMention }) ?? queue.endIndex
            queue.insert(item, at: insertAt)
        } else {
            queue.append(item)
        }
        // Bounded queue: drop the oldest non-mention first, then the oldest outright.
        while queue.count > rules.queueCap {
            let dropAt = queue.firstIndex(where: { !$0.isMention }) ?? queue.startIndex
            queue.remove(at: dropAt)
        }
        return true
    }

    // MARK: - Drain

    /// Pull the next item to speak, if the moment allows one. Call repeatedly (a pump); returns
    /// `nil` while TTS is busy, the rate cap is spent, or nothing is queued.
    mutating func nextItem(at now: TimeInterval, ttsBusy: Bool,
                           realtimeSessionActive: Bool) -> SpokenChatItem? {
        if realtimeSessionActive {
            queue.removeAll()   // suppressed entirely — stale chat must not replay later
            return nil
        }
        guard !ttsBusy, !queue.isEmpty else { return nil }

        spokenAt.removeAll { now - $0 > 60 }
        guard spokenAt.count < rules.rateCapPerMinute else { return nil }

        let item = queue.removeFirst()
        var body = item.text
        if item.duplicates > 1 { body += " — times \(item.duplicates)" }

        // Names once per burst: consecutive items by the same user inside the burst window
        // render as a continuation.
        let rendered: String
        if let last = lastSpoken, last.user == item.user, now - last.at <= rules.burstWindow {
            rendered = "And: \(body)"
        } else {
            rendered = "\(item.user) says: \(body)"
        }

        spokenAt.append(now)
        recentlySpoken.append((text: item.text, at: now))
        lastSpoken = (user: item.user, at: now)
        return SpokenChatItem(user: item.user, text: rendered, isMention: item.isMention)
    }

    /// Drop all pending state (call when a broadcast ends).
    mutating func reset() {
        queue.removeAll()
        spokenAt.removeAll()
        recentlySpoken.removeAll()
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
