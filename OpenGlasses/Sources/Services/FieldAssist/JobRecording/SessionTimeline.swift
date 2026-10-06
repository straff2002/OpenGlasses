import Foundation

/// The one timeline of a recorded job (Contracts/recorded-session.md §4, `timeline.json` version 1):
/// which media covers which stretch of the session, where it has gaps, what happened when, and
/// where a procedure probably took place.
///
/// The file is open, unlike the signed manifest that lists it: a reader passes over members and
/// event kinds it does not know and never refuses a timeline for carrying them. The schema version
/// is not in the file; the manifest states it (`timelineVersion`).
struct SessionTimeline: Equatable, Sendable {
    static let version = 1

    enum TrackKind: String, Codable, CaseIterable, Sendable {
        case video, audio
    }

    /// One unbroken stretch of recorded media. A stall, a pause or a restart begins a new part.
    struct Part: Equatable, Codable, Sendable {
        let partID: String
        /// Session time of the part's first sample.
        let tZero: SessionTime
        let duration: SessionTime

        var end: SessionTime { tZero + duration }
    }

    struct Track: Equatable, Sendable {
        let track: TrackKind
        var parts: [Part]
    }

    /// Why a stretch of a track has no media. A reason this version does not name is kept as
    /// written: a gap is a gap whatever caused it.
    struct GapReason: RawRepresentable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        static let stall = GapReason(rawValue: "stall")
        static let pause = GapReason(rawValue: "pause")
        static let restart = GapReason(rawValue: "restart")
        /// Frames taken out because the face blur could not process them.
        static let filter = GapReason(rawValue: "filter")
    }

    struct Gap: Equatable, Sendable {
        let track: TrackKind
        let from: SessionTime
        let to: SessionTime
        let reason: GapReason
    }

    enum EventKind: String, CaseIterable, Sendable {
        case turnStarted = "turn_started"
        case turnLogged = "turn_logged"
        case assistantSpeakingBegan = "assistant_speaking_began"
        case assistantSpeakingEnded = "assistant_speaking_ended"
        case toolCall = "tool_call"
        case photo
        case procedureStarted = "procedure_started"
        case procedureStep = "procedure_step"
        case procedureCompleted = "procedure_completed"
        case captureSilenced = "capture_silenced"
        case capturePassed = "capture_passed"
        case userMarker = "user_marker"
    }

    /// How well a logged turn's time is known: matched to the words in the audio, or left at the
    /// moment the job log wrote it down.
    enum Precision: String, Sendable {
        case aligned, coarse
    }

    /// Who a logged turn belongs to.
    enum Speaker {
        static let technician = "technician"
        static let assistant = "assistant"
    }

    struct Event: Equatable, Sendable {
        let t: SessionTime
        let kind: EventKind
        /// What the event points at: a logged turn's id in the job log, a tool's name, a procedure's
        /// id on `procedure_started` and `procedure_completed`, a step's id on `procedure_step`.
        var ref: String?
        var text: String?
        /// `turn_logged` only.
        var speaker: String?
        /// `turn_logged` only.
        var precision: Precision?

        init(t: SessionTime, kind: EventKind, ref: String? = nil, text: String? = nil,
             speaker: String? = nil, precision: Precision? = nil) {
            self.t = t
            self.kind = kind
            self.ref = ref
            self.text = text
            self.speaker = speaker
            self.precision = precision
        }
    }

    enum Certainty: String, Sendable {
        case certain, likely
    }

    /// "A procedure probably happened here." Advice for the office about where to look, and nothing
    /// more: the phone acts on a candidate in no way, and a timeline without one does not say that
    /// no procedure took place.
    struct Candidate: Equatable, Sendable {
        let from: SessionTime
        let to: SessionTime
        let certainty: Certainty
        let reason: String
    }

    /// A stretch of one part that no gap touches.
    struct ClearSpan: Equatable, Sendable {
        let partID: String
        let from: SessionTime
        let to: SessionTime
    }

    /// The session's zero as a wall time, in Unix milliseconds.
    var wallStart: Int64
    var tracks: [Track]
    var gaps: [Gap]
    var events: [Event]
    var candidates: [Candidate]

    init(wallStart: Int64, tracks: [Track] = [], gaps: [Gap] = [], events: [Event] = [],
         candidates: [Candidate] = []) {
        self.wallStart = wallStart
        self.tracks = tracks
        self.gaps = gaps
        self.events = events
        self.candidates = candidates
    }

    /// The stretches of a track that hold media: its parts with every gap on that track cut out, in
    /// time order. Something that lies inside one of these is on one part and in no gap.
    func clearSpans(_ kind: TrackKind) -> [ClearSpan] {
        let cuts = gaps.filter { $0.track == kind && $0.from < $0.to }
        var spans: [ClearSpan] = []
        for part in tracks.filter({ $0.track == kind }).flatMap(\.parts) where part.tZero < part.end {
            var pieces = [(from: part.tZero, to: part.end)]
            for cut in cuts {
                pieces = pieces.flatMap { piece -> [(from: SessionTime, to: SessionTime)] in
                    guard cut.from < piece.to, cut.to > piece.from else { return [piece] }
                    var kept: [(from: SessionTime, to: SessionTime)] = []
                    if piece.from < cut.from { kept.append((piece.from, cut.from)) }
                    if cut.to < piece.to { kept.append((cut.to, piece.to)) }
                    return kept
                }
            }
            spans += pieces.map { ClearSpan(partID: part.partID, from: $0.from, to: $0.to) }
        }
        return spans.enumerated().sorted { a, b in
            a.element.from != b.element.from ? a.element.from < b.element.from : a.offset < b.offset
        }.map(\.element)
    }

    /// The same timeline in the order it is written: video before audio, parts and gaps and
    /// candidates by time, events by time and otherwise as they were added.
    func normalized() -> SessionTimeline {
        func inOrder<T>(_ items: [T], _ before: (T, T) -> Bool?) -> [T] {
            items.enumerated().sorted { a, b in before(a.element, b.element) ?? (a.offset < b.offset) }
                .map(\.element)
        }
        func rank(_ kind: TrackKind) -> Int { TrackKind.allCases.firstIndex(of: kind) ?? 0 }
        var copy = self
        copy.tracks = inOrder(tracks) { rank($0.track) == rank($1.track) ? nil : rank($0.track) < rank($1.track) }
            .map { Track(track: $0.track, parts: inOrder($0.parts) { $0.tZero == $1.tZero ? nil : $0.tZero < $1.tZero }) }
        copy.gaps = inOrder(gaps) { a, b in
            if a.from != b.from { return a.from < b.from }
            return rank(a.track) == rank(b.track) ? nil : rank(a.track) < rank(b.track)
        }
        copy.events = inOrder(events) { $0.t == $1.t ? nil : $0.t < $1.t }
        copy.candidates = inOrder(candidates) { a, b in
            if a.from != b.from { return a.from < b.from }
            return a.to == b.to ? nil : a.to < b.to
        }
        return copy
    }

    /// Whether the assistant's synthetic voice may be in this recording's sound (Plan HQ P1
    /// item 3): true when the assistant spoke at least once without the capture being silenced
    /// for it — "Include Assistant Voice" was on, or the reply played somewhere the gate does not
    /// silence. False when every reply was silenced, or the assistant never spoke.
    ///
    /// Derived, not stored: the events already say it. The app notes `capture_silenced` straight
    /// after `assistant_speaking_began` whenever the gate silences a reply, so a reply with no
    /// silence noted between its start and its end (or the end of the timeline) was let through.
    /// "May": the timeline does not record the output route, and a reply played into the glasses
    /// is let through without reaching the microphone.
    var assistantVoiceMayBeIncluded: Bool {
        var speaking = false
        var silencedDuringReply = false
        for event in normalized().events {
            switch event.kind {
            case .assistantSpeakingBegan:
                if speaking, !silencedDuringReply { return true }
                speaking = true
                silencedDuringReply = false
            case .captureSilenced:
                if speaking { silencedDuringReply = true }
            case .assistantSpeakingEnded:
                if speaking, !silencedDuringReply { return true }
                speaking = false
            default:
                break
            }
        }
        return speaking && !silencedDuringReply
    }
}

// MARK: - timeline.json

extension SessionTimeline {
    enum Refusal: Error, Equatable {
        /// Not JSON, or not the shape version 1 gives a timeline.
        case malformed
    }

    /// The bytes of `timeline.json`: in written order, keys sorted, nothing a reader does not need.
    func encoded() throws -> Data {
        let ordered = normalized()
        let file = File(
            clock: File.Clock(wallStart: ordered.wallStart, monotonicZero: 0),
            tracks: ordered.tracks.map { File.Track(track: $0.track.rawValue, parts: $0.parts) },
            gaps: ordered.gaps.map {
                File.Gap(track: $0.track.rawValue, from: $0.from, to: $0.to, reason: $0.reason.rawValue)
            },
            events: ordered.events.map {
                .known(File.Event(t: $0.t, kind: $0.kind.rawValue, ref: $0.ref, text: $0.text,
                                  speaker: $0.speaker, precision: $0.precision?.rawValue))
            },
            candidates: ordered.candidates.map {
                File.Candidate(from: $0.from, to: $0.to, certainty: $0.certainty.rawValue, reason: $0.reason)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    /// Reads a version 1 timeline. Members and event kinds this version does not know are passed
    /// over, as are tracks of a kind it does not know (with their gaps) and candidates of a
    /// certainty it does not know. A clock whose zero is not the session's zero is refused: every
    /// time in the file would mean something else.
    static func decode(_ data: Data) throws -> SessionTimeline {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              file.clock.monotonicZero == 0 else { throw Refusal.malformed }
        return SessionTimeline(
            wallStart: file.clock.wallStart,
            tracks: file.tracks.compactMap { track in
                TrackKind(rawValue: track.track).map { Track(track: $0, parts: track.parts) }
            },
            gaps: file.gaps.compactMap { gap in
                TrackKind(rawValue: gap.track).map {
                    Gap(track: $0, from: gap.from, to: gap.to, reason: GapReason(rawValue: gap.reason))
                }
            },
            events: file.events.compactMap { entry in
                guard case let .known(event) = entry, let kind = EventKind(rawValue: event.kind) else { return nil }
                return Event(t: event.t, kind: kind, ref: event.ref, text: event.text, speaker: event.speaker,
                             precision: event.precision.flatMap(Precision.init(rawValue:)))
            },
            candidates: file.candidates.compactMap { candidate in
                Certainty(rawValue: candidate.certainty).map {
                    Candidate(from: candidate.from, to: candidate.to, certainty: $0, reason: candidate.reason)
                }
            })
    }

    /// The file as written.
    private struct File: Codable {
        struct Clock: Codable {
            let wallStart: Int64
            let monotonicZero: Int
        }
        struct Track: Codable {
            let track: String
            let parts: [Part]
        }
        struct Gap: Codable {
            let track: String
            let from: SessionTime
            let to: SessionTime
            let reason: String
        }
        struct Event: Codable {
            let t: SessionTime
            let kind: String
            let ref: String?
            let text: String?
            let speaker: String?
            let precision: String?
        }
        /// An event of a kind this version knows, read in full; any other is only noted, so that
        /// whatever shape a later kind takes it cannot make the file unreadable.
        enum Entry: Codable {
            case known(Event)
            case unknown

            private enum Key: String, CodingKey { case kind }

            init(from decoder: Decoder) throws {
                let kind = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .kind)
                self = EventKind(rawValue: kind) == nil ? .unknown : .known(try Event(from: decoder))
            }

            func encode(to encoder: Encoder) throws {
                if case let .known(event) = self { try event.encode(to: encoder) }
            }
        }
        struct Candidate: Codable {
            let from: SessionTime
            let to: SessionTime
            let certainty: String
            let reason: String
        }

        let clock: Clock
        let tracks: [Track]
        let gaps: [Gap]
        let events: [Entry]
        let candidates: [Candidate]
    }
}
