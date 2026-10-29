import Foundation

/// The two cues that bracket the wearer's turn (Plan KD P1): "talk now" and "got it".
///
/// They were single notes — 880 Hz to start, 440 Hz to end — and in build 581 the wearer could not
/// tell from the sound alone whether the app had started listening, stopped, or was about to
/// answer. Two short notes each now, as contours rather than pitches: the start rises, the end
/// falls, which is the difference an ear picks up first, whatever the speaker.
///
/// They also have to be told from every other sound the app makes:
/// - the connect pair (660 → 990 Hz) and the temple unmute pair (440 → 660 Hz) also rise, and the
///   temple mute pair (660 → 440 Hz) and the end-of-conversation pair (440 → 330 Hz) also fall.
///   None of their pitches is used here, and both cues here are quicker than any of them.
/// - the link-lost fall and the temple "ended" fall are three notes, and the session-restored
///   triad (523, 659, 784 Hz) rises through three. Their pitches are not used here either.
/// Under a third of a second each, so the start cue is over before the wearer begins talking and
/// the end cue does not hold up the answer.
enum ListeningCuePolicy {

    typealias Note = GlassesLinkCuePolicy.Note

    /// F♯5 then C♯6: a rising fifth. Played the moment the mic is live, just before recording.
    static let start: [Note] = [
        Note(start: 0.000, frequency: 740, duration: 0.070),
        Note(start: 0.085, frequency: 1109, duration: 0.090),
    ]

    /// F5 then C♯5: a falling third. Played when the wearer's words have been taken.
    static let end: [Note] = [
        Note(start: 0.000, frequency: 698, duration: 0.070),
        Note(start: 0.085, frequency: 554, duration: 0.090),
    ]

    static func seconds(_ notes: [Note]) -> TimeInterval { notes.map(\.end).max() ?? 0 }
}
