import Foundation

/// Decides, turn by turn, where the interpreter's audio plays.
///
/// A model reply arrives as audio with its transcript alongside, and nothing says who it is for
/// until the transcript can be read. So each turn's audio is held until it can, then released to
/// the ear or the speaker. The failure that matters is a private line played aloud, so every doubt
/// resolves to the ear: a transcript that hasn't settled by ``ceiling``, a turn that ends unread, a
/// speaker line that can't get its turn. The worst outcome of that is the wearer hearing a line the
/// other person should have.
///
/// The output is a single switch for the whole audio path, and flipping it moves whatever is still
/// playing. Going to the ear does that at once, since a tail heard privately costs nothing. Going to
/// the speaker waits for the playback before it to finish, or the end of a private line would come
/// out aloud.
///
/// Pure: time and playback state are passed in, and the caller applies the ``Effect``s in order.
struct InterpreterTurnRouter: Equatable {

    enum Effect: Equatable {
        case setOutput(InterpreterOutput)
        case play(Data)
        /// The conversation changed direction. One voice in a room is a TV as easily as a person,
        /// and only this counts as someone being there (`LiveIdlePolicy`).
        case exchanged
    }

    /// How long a turn's audio is held for its transcript. A placeholder until the device pass.
    static let ceiling: TimeInterval = 1.2
    /// How long the mic stays closed after the speaker goes quiet, for the room to.
    static let speakerTail: TimeInterval = 0.25
    /// The longest anything waits on playback that may never report finishing.
    static let drainBound: TimeInterval = 15

    private enum Line: Equatable {
        case none
        case holding(since: Date)
        /// For the speaker, behind a private line still playing.
        case waitingForQuiet(since: Date, finished: Bool)
        case released(InterpreterOutput)
    }

    let pair: InterpreterPair
    private(set) var output: InterpreterOutput = .ear
    private var line: Line = .none
    private var held: [Data] = []
    private var transcript = ""
    private var lastHeard: InterpreterOutput?
    /// When the last speaker line had everything it was going to get.
    private var speakerLineEnded: Date?
    private var speakerQuietSince: Date?
    private var disclosed = false

    init(pair: InterpreterPair) {
        self.pair = pair
    }

    /// Whether the mic may be sent. Closed while the speaker is live, or the session would hear
    /// itself and translate its own voice.
    var micOpen: Bool { output == .ear }

    /// Whether audio is waiting to be played, which a goodbye has to wait for.
    var holdsAudio: Bool { !held.isEmpty }

    // MARK: - Events

    mutating func audio(_ data: Data, now: Date) -> [Effect] {
        switch line {
        case .released:
            return [.play(data)]
        case .none:
            held = [data]
            line = .holding(since: now)
            return []
        case .holding, .waitingForQuiet(_, finished: false):
            held.append(data)
            return []
        case .waitingForQuiet(_, finished: true):
            // A new turn behind a line that never got the speaker. Mixing the two could play one
            // aloud on the other's reading, so the old line gives up and goes private.
            let effects = release(to: .ear, finished: true, now: now)
            held = [data]
            line = .holding(since: now)
            return effects
        }
    }

    /// A piece of the output transcript. Ignored outside a held turn: once a line has gone it can't
    /// change, and text arriving after a turn ended belongs to no turn.
    mutating func transcript(_ text: String, now: Date) -> [Effect] {
        guard case .holding = line else { return [] }
        transcript = ScriptAwareJoiner.join(transcript, text)
        guard let reading = InterpreterLanguageReader.output(for: transcript, pair: pair) else { return [] }
        return route(reading, finished: false, now: now)
    }

    mutating func turnComplete(now: Date) -> [Effect] {
        defer { transcript = "" }
        switch line {
        case .none:
            return []
        case .holding:
            let reading = InterpreterLanguageReader.output(for: transcript, pair: pair)
            return route(reading ?? .ear, finished: true, now: now, confident: reading != nil)
        case .waitingForQuiet(let since, _):
            line = .waitingForQuiet(since: since, finished: true)
            return []
        case .released(let destination):
            line = .none
            if destination == .speaker { speakerLineEnded = now }
            return []
        }
    }

    /// The turn was cut off, or the connection went. What was held is dropped, unheard, and the
    /// output goes back to the ear rather than wait to find out what comes next.
    mutating func interrupted() -> [Effect] {
        held = []
        transcript = ""
        line = .none
        speakerLineEnded = nil
        speakerQuietSince = nil
        guard output == .speaker else { return [] }
        output = .ear
        return [.setOutput(.ear)]
    }

    /// The speaker is needed for the line that tells the other person this is AI translation. Once
    /// a session: an empty result means it has been said. Treated as a speaker line, so ``tick``
    /// ends it the same way.
    mutating func disclose(now: Date) -> [Effect] {
        guard !disclosed else { return [] }
        disclosed = true
        output = .speaker
        speakerLineEnded = now
        speakerQuietSince = nil
        return [.setOutput(.speaker)]
    }

    /// Time passing. `playbackPending` is whether anything is still coming out of the output.
    mutating func tick(now: Date, playbackPending: Bool) -> [Effect] {
        var effects: [Effect] = []
        switch line {
        case .holding(let since) where now.timeIntervalSince(since) >= Self.ceiling:
            effects += route(.ear, finished: false, now: now, confident: false)
        case .waitingForQuiet(let since, let finished):
            if !playbackPending {
                effects += release(to: .speaker, finished: finished, now: now)
            } else if now.timeIntervalSince(since) >= Self.drainBound {
                effects += release(to: .ear, finished: finished, now: now)
            }
        default:
            break
        }
        effects += closeSpeakerIfDone(now: now, playbackPending: playbackPending)
        return effects
    }

    // MARK: - Routing

    private mutating func route(_ destination: InterpreterOutput, finished: Bool, now: Date,
                                confident: Bool = true) -> [Effect] {
        var effects: [Effect] = []
        if confident {
            if let lastHeard, lastHeard != destination { effects.append(.exchanged) }
            lastHeard = destination
        }
        if destination == .speaker, output != .speaker {
            line = .waitingForQuiet(since: now, finished: finished)
            return effects
        }
        return effects + release(to: destination, finished: finished, now: now)
    }

    private mutating func release(to destination: InterpreterOutput, finished: Bool, now: Date) -> [Effect] {
        var effects: [Effect] = []
        if output != destination {
            output = destination
            effects.append(.setOutput(destination))
        }
        effects += held.map(Effect.play)
        held = []
        line = finished ? .none : .released(destination)
        speakerQuietSince = nil
        speakerLineEnded = destination == .speaker && finished ? now : nil
        return effects
    }

    /// Back to the ear once the speaker line is over and has gone quiet, which reopens the mic.
    private mutating func closeSpeakerIfDone(now: Date, playbackPending: Bool) -> [Effect] {
        guard output == .speaker, let ended = speakerLineEnded else { return [] }
        if playbackPending, now.timeIntervalSince(ended) < Self.drainBound {
            speakerQuietSince = nil
            return []
        }
        if !playbackPending {
            let quiet = speakerQuietSince ?? now
            speakerQuietSince = quiet
            guard now.timeIntervalSince(quiet) >= Self.speakerTail else { return [] }
        }
        output = .ear
        speakerLineEnded = nil
        speakerQuietSince = nil
        return [.setOutput(.ear)]
    }
}
