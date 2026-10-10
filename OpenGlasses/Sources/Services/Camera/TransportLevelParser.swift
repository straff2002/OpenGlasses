import Foundation

/// Plan HW P1 — the radio link the glasses are on, as far as the SDK's own log says.
///
/// The SDK has no API for this. It names three link levels in its log, and its camera module
/// says what two of them are in so many words: a stream "requires medium (BTC) or high (WiFi)
/// bandwidth link". So `high` is Wi-Fi and `medium` is Bluetooth Classic. `low` is Bluetooth Low
/// Energy **by elimination**: the SDK has those three transports and no text ties the name to
/// the radio. Treat that one as inferred until a device shows otherwise.
enum GlassesTransportLevel: String, Equatable {
    case wifi
    case bluetoothClassic
    case bluetoothLowEnergy
    /// Nothing readable was said. Never a guess: a line the parser does not recognise leaves
    /// this, and so does a log with no such line in it.
    case unknown
}

/// Plan HW P1 — reads the link level out of the SDK's log lines (pure).
///
/// Two lines are recognised, both from the SDK's device manager. The wording of the parts in
/// angle brackets is unknown until a device shows them, so the parser looks for the words that
/// are fixed and a whole-word level between or after them:
///
///     DeviceManager: Device <id> connected with <level> link, requesting firmware version
///     DeviceManager: .medium link unavailable (<reason>), falling back to .low
///
/// Lines are fed in the order they were written and **the latest one that speaks about the link
/// wins**. A line that speaks about it and cannot be read (a level word nobody has seen, two
/// level words where one was expected) makes the answer `unknown` rather than leaving an older
/// level standing: the newest statement is the one that is true now, and it was not understood.
/// A line that says nothing about the link is ignored, which includes the transport's own error
/// lines and "Neither .medium nor .low link levels are available": neither names a link in use.
///
/// The lines carry device identifiers. Nothing but the level leaves this type.
struct TransportLevelParser: Equatable {

    /// What the latest line about the link said.
    private(set) var level: GlassesTransportLevel = .unknown

    /// The readable levels seen since `beginSession()`, starting with the one in force then.
    private var sessionLevels: Set<GlassesTransportLevel> = []

    /// More than one level was in force during the session. This is the question the device
    /// session asks: does the link ever change under a running stream.
    var changedDuringSession: Bool { sessionLevels.count > 1 }

    /// A stream started. The level in force now is where the session begins, and what was seen
    /// before it is history.
    mutating func beginSession() {
        sessionLevels = level == .unknown ? [] : [level]
    }

    mutating func consume(_ line: String) {
        guard let statement = Self.statement(in: line) else { return }
        level = statement
        if statement != .unknown { sessionLevels.insert(statement) }
    }

    mutating func consume<Lines: Sequence>(_ lines: Lines) where Lines.Element == String {
        for line in lines { consume(line) }
    }

    /// What one line says about the link: a level, `unknown` for a line that is about the link
    /// and cannot be read, and nil for a line that is not about it at all.
    static func statement(in line: String) -> GlassesTransportLevel? {
        if let between = firstCapture(of: connectedPattern, in: line) {
            return soleLevel(in: between)
        }
        if let after = firstCapture(of: fallbackPattern, in: line) {
            return soleLevel(in: after)
        }
        return nil
    }

    // MARK: - Reading a line

    /// "connected with … link", and not the tail of "disconnected with … link": the transport's
    /// error lines are full of the second.
    private static let connectedPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z])connected with\b(.{0,80}?)\blink\b"#, options: [.caseInsensitive])

    /// What follows "falling back to", up to the end of the line.
    private static let fallbackPattern = try? NSRegularExpression(
        pattern: #"\bfalling back to\b(.{0,80})"#, options: [.caseInsensitive])

    /// A level as a whole word, whatever is in front of it: `medium`, `.medium`,
    /// `LinkLevel.medium`. Not part of a longer word, so "lowest" and "highlight" are not levels.
    private static let levelPattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(low|medium|high)(?![A-Za-z0-9_])"#,
        options: [.caseInsensitive])

    private static func firstCapture(of pattern: NSRegularExpression?, in line: String) -> String? {
        let whole = NSRange(line.startIndex..., in: line)
        guard let match = pattern?.firstMatch(in: line, range: whole),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    /// The one level named in `text`, or `unknown` when it names none or more than one.
    private static func soleLevel(in text: String) -> GlassesTransportLevel {
        let whole = NSRange(text.startIndex..., in: text)
        let words = Set((levelPattern?.matches(in: text, range: whole) ?? []).compactMap { match in
            Range(match.range(at: 1), in: text).map { text[$0].lowercased() }
        })
        guard words.count == 1, let word = words.first else { return .unknown }
        switch word {
        case "high": return .wifi
        case "medium": return .bluetoothClassic
        case "low": return .bluetoothLowEnergy   // inferred: see `GlassesTransportLevel`
        default: return .unknown
        }
    }
}
