import Foundation

/// The done tone (Plan LA §5): what the wearer hears instead of a spoken reply when everything
/// they asked for has happened. Pure data and rules; `TextToSpeechService.playQuietDoneTone()`
/// plays it.
///
/// A soft rising fifth (decision 6), C6 then G6, a quarter of a second, at half the other
/// earcons' level (−6 dB). Every rising fifth lower down is already a sound the app makes — the
/// listening start (F♯5 → C♯6), the connect pair (660 → 990 Hz) and the temple unmute pair
/// (440 → 660 Hz) — so this one sits above all of them, half an octave clear of the nearest.
/// `QuietDoneCueTests` holds it apart from every list the app plays, by `minimumSemitoneGap`.
/// There is no failed variant: a failure is always spoken.
enum QuietDoneCue {

    typealias Note = GlassesLinkCuePolicy.Note

    static let notes: [Note] = [
        Note(start: 0.000, frequency: 1047, duration: 0.090),
        Note(start: 0.110, frequency: 1568, duration: 0.140),
    ]

    /// The player's volume: the other earcons play at 0.7; −6 dB is half the amplitude.
    static let volume: Float = 0.35

    static var seconds: TimeInterval { notes.map(\.end).max() ?? 0 }

    /// The line VoiceOver users hear after the tone when "Speak What Each Sound Means" is on
    /// (decision 5), and the sound tour's line.
    static let spokenMeaning = "Done"
    /// Worded like every other lesson in the tour ("This sound means…").
    static let tourLine = "This sound means what you asked for has happened."

    /// Whether "Done" follows the tone (Plan LA §7).
    static func speaksMeaning(voiceOverRunning: Bool, spokenCuesOn: Bool) -> Bool {
        voiceOverRunning && spokenCuesOn
    }

    // MARK: - Telling it apart

    /// Two cues with the same number of notes and the same contour must differ, note for note,
    /// by at least this many semitones somewhere — the margin the distinctness test states.
    static let minimumSemitoneGap = 3.0

    enum Contour: Equatable { case rising, falling, flat, mixed }

    static func contour(_ frequencies: [Double]) -> Contour {
        guard frequencies.count > 1 else { return .flat }
        let steps = zip(frequencies, frequencies.dropFirst()).map { $1 - $0 }
        if steps.allSatisfy({ $0 > 0 }) { return .rising }
        if steps.allSatisfy({ $0 < 0 }) { return .falling }
        if steps.allSatisfy({ $0 == 0 }) { return .flat }
        return .mixed
    }

    static func semitones(_ a: Double, _ b: Double) -> Double { abs(12 * log2(a / b)) }

    /// Whether a listener could tell `a` from `b`: a different number of notes, a different
    /// contour, or the same shape at pitches at least `minimumSemitoneGap` apart on some note.
    static func isDistinct(_ a: [Double], from b: [Double]) -> Bool {
        guard a.count == b.count, contour(a) == contour(b) else { return true }
        let largestGap = zip(a, b).map { semitones($0, $1) }.max() ?? 0
        return largestGap >= minimumSemitoneGap
    }

    static var frequencies: [Double] { notes.map(\.frequency) }
}

/// "What was that?" straight after a quiet turn (Plan LA §6, decision 7): for 30 seconds the
/// reply that was not spoken can be heard by asking, without a model call. Pure.
struct QuietReplayWindow: Equatable {
    static let seconds: TimeInterval = 30

    static let phrases: [String] = [
        "what was that", "what did you do", "what did you just do", "say it", "say that",
        "say that again", "what happened", "what did you say", "repeat that",
    ]

    private(set) var reply: String?
    private(set) var endedAt: Date?

    /// A turn ended with the done tone; its reply can be asked for.
    mutating func noteQuietTurn(reply: String, at time: Date) {
        self.reply = reply
        endedAt = time
    }

    /// Any other turn closes the window.
    mutating func close() {
        reply = nil
        endedAt = nil
    }

    /// The reply to speak when `utterance` asks for it inside the window, else nil.
    func replay(for utterance: String, at time: Date) -> String? {
        guard let reply, let endedAt, time.timeIntervalSince(endedAt) <= Self.seconds,
              time >= endedAt, Self.asksForReplay(utterance) else { return nil }
        return reply
    }

    static func asksForReplay(_ utterance: String) -> Bool {
        let cleaned = utterance.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .filter { $0.isLetter || $0 == " " || $0 == "'" }
            .split(separator: " ").joined(separator: " ")
        let withoutPlease = cleaned.replacingOccurrences(of: "please", with: "")
            .split(separator: " ").joined(separator: " ")
        return phrases.contains(withoutPlease) || phrases.contains(cleaned)
    }
}

/// The prompt's exception to "acknowledge before every tool" (Plan LA §3). Pure.
enum QuietAfterActionsPrompt {
    static let preambleException = """
       EXCEPTION (Quiet After Actions is on): for a request that only changes something — lights, \
    a timer or alarm, music playback, a note, the torch, brightness — call the tool straight away \
    with no acknowledgement first, then reply in a few words. Anything that looks something up \
    keeps the acknowledgement.
    """

    /// The line added after the acknowledgement rule, or nothing.
    static func exception(enabled: Bool, simpleMode: Bool) -> String {
        enabled && !simpleMode ? "\n" + preambleException : ""
    }
}

/// The wire message for the watch's done tap (Plan LA P3). The watch target compiles none of the
/// phone's files, so it spells the same two strings out; `QuietDoneCueTests` reads its source and
/// fails if they drift.
enum QuietDoneWatchMessage {
    static let key = "event"
    static let value = "quietDone"
    static var payload: [String: Any] { [key: value] }
}
