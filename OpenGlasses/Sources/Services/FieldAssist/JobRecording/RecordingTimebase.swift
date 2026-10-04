import Foundation

/// What a recorder says about one part when it stops: for each track, the monotonic clock's reading
/// at the first sample and how long the track runs (Plan HE §2).
///
/// A recorder starts each track at zero inside its own file, at whatever moment that track's first
/// sample happened to arrive, so the file by itself does not say when anything in it took place —
/// nor how far the sound and the pictures are from each other. These two readings do: placed on the
/// job's `SessionClock` they give every part a `tZero` and a `duration`, and what lies between one
/// part and the next is written down as a gap rather than left to be inferred.
///
/// Pure: the readings are inputs, and the clock they were taken on must be the one the session's
/// zero was taken on.
struct RecordingTimebase: Equatable, Sendable {

    struct Track: Equatable, Sendable {
        /// The monotonic clock's reading, in seconds, at the track's first sample.
        let firstSample: TimeInterval
        /// From the first sample to the end of the last one, in seconds.
        let duration: TimeInterval

        init(firstSample: TimeInterval, duration: TimeInterval) {
            self.firstSample = firstSample
            self.duration = duration
        }
    }

    /// Nil when the part holds no samples of that kind.
    var video: Track?
    var audio: Track?

    init(video: Track? = nil, audio: Track? = nil) {
        self.video = video
        self.audio = audio
    }

    /// Whether anything at all was recorded.
    var isEmpty: Bool { video == nil && audio == nil }

    /// One recorded part on the session's clock. The sound and the pictures of a part are in one
    /// file and share its `partID`; each has its own `tZero`, because each began at its own first
    /// sample.
    struct PlacedPart: Equatable, Codable, Sendable {
        let partID: String
        let video: SessionTimeline.Part?
        let audio: SessionTimeline.Part?
        /// Why the recorder stopped at the end of this part, when another part follows it. It is
        /// the reason written on the gap between them.
        var endedBy: String?

        /// Where the part's media ends, whichever track runs later.
        var end: SessionTime? { [video?.end, audio?.end].compactMap { $0 }.max() }
        var start: SessionTime? { [video?.tZero, audio?.tZero].compactMap { $0 }.min() }
    }

    /// This part on a session's clock. A track that is missing, that ran for less than a
    /// millisecond, or whose readings are not numbers has no entry: a part of no length covers
    /// nothing. A first sample from before the session's zero is held at zero.
    func placed(partID: String, on clock: SessionClock, endedBy: SessionTimeline.GapReason? = nil) -> PlacedPart {
        func part(_ track: Track?) -> SessionTimeline.Part? {
            guard let track, track.firstSample.isFinite, track.duration.isFinite else { return nil }
            let duration = SessionTime(seconds: track.duration)
            guard duration > .zero else { return nil }
            return SessionTimeline.Part(partID: partID, tZero: max(.zero, clock.time(monotonic: track.firstSample)),
                                        duration: duration)
        }
        return PlacedPart(partID: partID, video: part(video), audio: part(audio), endedBy: endedBy?.rawValue)
    }

    /// The timeline's tracks and gaps for a recording's parts.
    ///
    /// Each track lists its parts in time order. Between one part of a track and the next there is
    /// a gap, from where the earlier one ends to where the later one begins, with the reason the
    /// earlier one ended — `restart` when none was given. Parts that touch or overlap leave no gap.
    /// A track with no parts is not listed.
    static func tracksAndGaps(_ parts: [PlacedPart]) -> (tracks: [SessionTimeline.Track], gaps: [SessionTimeline.Gap]) {
        var tracks: [SessionTimeline.Track] = []
        var gaps: [SessionTimeline.Gap] = []
        for kind in SessionTimeline.TrackKind.allCases {
            let onTrack: [(part: SessionTimeline.Part, endedBy: String?)] = parts.compactMap { item in
                (kind == .video ? item.video : item.audio).map { ($0, item.endedBy) }
            }
            // By time, and as given where two begin together.
            let placed = onTrack.enumerated().sorted { a, b in
                a.element.part.tZero != b.element.part.tZero ? a.element.part.tZero < b.element.part.tZero : a.offset < b.offset
            }.map(\.element)
            guard !placed.isEmpty else { continue }
            tracks.append(SessionTimeline.Track(track: kind, parts: placed.map(\.part)))
            for (earlier, later) in zip(placed, placed.dropFirst()) where earlier.part.end < later.part.tZero {
                let reason = earlier.endedBy.map(SessionTimeline.GapReason.init(rawValue:)) ?? .restart
                gaps.append(SessionTimeline.Gap(track: kind, from: earlier.part.end, to: later.part.tZero, reason: reason))
            }
        }
        return (tracks, gaps)
    }
}
