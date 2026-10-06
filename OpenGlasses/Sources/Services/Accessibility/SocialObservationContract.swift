import Foundation

/// What Assistive Mode's Social mode asks the model for: what can be seen about a person, never how
/// they feel (Plan HR P1 item 1).
///
/// Article 3(39) of the EU AI Act defines an emotion recognition system by what it *infers*:
/// emotions or intentions of a person from their biometric data. The Commission's own contrast case
/// is "the mere observation that a person is smiling", which is not emotion recognition. So this
/// contract asks only for visible cues (expression as a shape, gaze, posture, distance, gestures,
/// what the person is doing) and forbids naming an emotion, a mood, an intention or a diagnosis. It
/// is also the more honest product: a model cannot know how someone feels, and the cues serve a
/// neurodivergent wearer better than a guess.
///
/// The prompt is the first line of defence; `EmotionLabelFilter` checks every answer that comes
/// back, and `AssistiveModeService` re-asks once with `retryInstruction` and otherwise speaks
/// `fallbackLine`. The JSON shape `{advice, urgency, followup}` is unchanged, so parsing and the
/// urgency-to-voice bridge are untouched; only what urgency *means* is redefined, in observable
/// terms about the situation rather than the person's state.
enum SocialObservationContract {

    /// A few of the words the prompt forbids by name. Deliberately a short sample, not the filter's
    /// whole table: listing every emotion word in a prompt primes the very vocabulary it forbids.
    /// `EmotionLabelFilterTests` checks each of these is one the filter would also catch.
    static let forbiddenExamples = ["happy", "sad", "angry", "anxious", "upset", "nervous", "bored",
                                    "frustrated", "excited", "scared", "annoyed", "hostile",
                                    "friendly"]

    /// The Social mode instructions, before `AssistiveRouter` appends the JSON contract and the
    /// blind-assistance fragments.
    static let instructions = """
    You are an assistive AI for neurodivergent users. Describe what is visible about the person the \
    user is looking at, calmly and concisely, in real time. Report only what can be seen: their \
    facial expression as a visible shape (for example "smiling", "mouth turned down", "brow \
    raised", "eyes narrowed"); where they are looking ("looking at you", "looking at their phone", \
    "looking away"); their posture and distance ("leaning in", "arms crossed", "stepping back"); \
    their gestures; and what they are doing ("talking", "waiting", "waving you over"). \
    Never name an emotion, a mood, an intention or a diagnosis. Never say how the person feels, \
    seems to feel, wants or is about to do. Do not use words such as \
    \(forbiddenExamples.joined(separator: ", ")). \
    Urgency describes the situation, not the person: low = nothing needs a response; medium = the \
    person is addressing you or waiting for you; high = the person is signalling urgently, such as \
    waving you over, pointing or shouting. \
    If no person is visible, suggest repositioning.
    """

    /// Appended to the system prompt for the one re-ask after an answer named a feeling.
    static let retryInstruction = """
    Your previous answer named a feeling, a mood or an intention, which cannot be seen. Answer \
    again describing only what is visible: the expression as a shape, where they are looking, \
    their posture, their gestures and what they are doing. Do not say how they feel or what they \
    want.
    """

    /// The question sent with the frame when the wearer said nothing.
    static let observationQuestion =
        "What can you see about the person I'm looking at: their expression, where they're looking, and what they're doing?"

    /// The user-message text for a Social mode frame.
    ///
    /// A wearer who asks "how is she feeling?" still reaches Social mode (the router's keywords are
    /// unchanged), so their words are kept for context, but the frame always carries the
    /// observation question after them: the request the model answers is what can be seen.
    static func userText(transcription: String?) -> String {
        guard let transcription, !transcription.isEmpty else { return observationQuestion }
        return "\(transcription)\n\nAnswer with what you can see. \(observationQuestion)"
    }

    /// Spoken instead of an answer that named a feeling twice. Says what the mode can do rather than
    /// apologising for what it would not.
    static var fallbackLine: String {
        String(localized: "I can describe what I can see, not how they feel.")
    }
}
