import Foundation

/// Plan FF P1/PR4 — what to do when a requested sharp capture arrives unusable, and what to say.
///
/// # The rule this encodes
///
/// A blind wearer asked for text to be read. Three things can come back: a picture good enough to
/// read, a picture that is not, and no picture at all. Only the first may produce an answer. The
/// other two have to produce something the wearer can *act on* — a move to make, or the part of the
/// text that was actually legible — and must never produce the digits, names, dates or instructions
/// that were not. That last clause is the whole of Plan FF P0's faithful-reading rule applied at
/// the one boundary where the temptation is strongest: the model has a blurry picture of a
/// medication box and a great deal of prior knowledge about what medication boxes say.
///
/// # Bounded retries
///
/// Exactly one automatic re-capture. Zero would waste the one case that reliably fixes itself — a
/// hand that moved during the shutter. Two or more turns a reading request into a multi-second
/// silence with the camera firing repeatedly, which is both a battery cost and, for someone who
/// cannot see the shutter, an unexplained pause. The re-capture still goes through
/// `LookCloselyPolicy`, so posture and cooldown keep their meaning: a retry is a *request* to
/// capture, not a bypass.
enum ReadingCaptureOutcome {

    /// At most one automatic re-capture per reading request.
    static let maximumAutomaticRetries = 1

    enum Decision: Equatable {
        /// The picture is good enough. Inject it and ask the model to read from it.
        case inject
        /// Unusable, and a retry has not been spent yet.
        case retry(CaptureQualityReport.Quality)
        /// Unusable, and the retry is spent. Carries the function result to return.
        case explain(String)
    }

    /// Decide what happens to a measured capture.
    ///
    /// - Parameters:
    ///   - quality: the measured verdict.
    ///   - attemptsSoFar: how many captures this request has already made, including this one.
    ///   - isReadingRequest: whether the wearer asked for *text*. Only changes the wording of the
    ///     instruction — a reading request gets "closer to the text", anything else gets the
    ///     general line — because wrong advice costs a wearer who cannot check it a wasted move.
    static func decide(quality: CaptureQualityReport.Quality,
                       attemptsSoFar: Int,
                       isReadingRequest: Bool) -> Decision {
        switch quality {
        case .usable:
            return .inject
        case .tooBlurry, .tooDark, .undecodable:
            if attemptsSoFar <= maximumAutomaticRetries { return .retry(quality) }
            return .explain(instruction(for: quality, isReadingRequest: isReadingRequest))
        }
    }

    // MARK: - Copy
    //
    // Every string below is a *directive to the model*, in the same shape Plan FF P0 rewrote the
    // timeout and failure copy into: it names the one sentence to say to the wearer, states that
    // the detail is still unread, and forbids filling it in. The live model holds the audio floor
    // during a session, so this is how a spoken instruction actually reaches the wearer; a second
    // voice speaking over the model is a Plan FF PR5 concern, not a reading one.

    /// The concise instruction for an unusable picture.
    static func instruction(for quality: CaptureQualityReport.Quality,
                            isReadingRequest: Bool) -> String {
        let spoken: String
        switch quality {
        case .tooDark:
            spoken = "It's too dark to read; find more light."
        case .tooBlurry:
            spoken = isReadingRequest
                ? "Hold still and move a little closer to the text."
                : "Hold still for a moment so I can get a sharper picture."
        case .undecodable, .usable:
            spoken = "The picture didn't come through. Hold the item steady and I'll try again."
        }
        return """
            The photo arrived but is not good enough to read fine detail from, and a second attempt \
            was no better. Say exactly this to the user, in one short sentence: "\(spoken)" The \
            detail that needed the photo is still unread — do NOT answer it from the streamed view \
            or from what you expect this kind of item to say. Never guess characters, digits, \
            names, dates or instructions. Offer to try again.
            """
    }

    /// What to return when the picture never arrived at all.
    ///
    /// Reasons are the chokepoint's own, so the wearer is told the true one. `noFreshView` — a
    /// picture exists and is no longer a current view — is the case a stale-session or
    /// stale-by-time refusal lands on, and it must not be reported as "the camera failed".
    static func unavailable(_ reason: FilteredStillResult.Reason) -> String {
        let spoken: String
        switch reason {
        case .noStill:
            spoken = "I'm not getting a picture from the camera right now."
        case .noFreshView:
            spoken = "The only picture I have is out of date, so I didn't read from it."
        case .filterUnavailable, .filterNotWired:
            spoken = "I couldn't prepare the picture, so I haven't read it."
        }
        return """
            No usable photo was added to your view. Say exactly this to the user, in one short \
            sentence: "\(spoken)" The detail that needed the photo is still unread — do NOT answer \
            it from the streamed view or from what you expect this kind of item to say. Never guess \
            characters, digits, names, dates or instructions. Offer to try again.
            """
    }

    // MARK: - Partial transcription

    /// Minimum per-block Vision confidence for text to be offered as a partial transcription.
    ///
    /// Above `OCRService`'s own 0.3 floor on purpose. 0.3 is the right threshold for feeding a
    /// whole page to a model that will weigh it; this is text about to be read aloud, verbatim, to
    /// someone who cannot check it against the page, and a half-guessed digit is worse than
    /// silence.
    static let partialConfidenceFloor: Float = 0.5

    /// The confidently-recognised blocks of an OCR pass, in reading order, or nil when none clear
    /// the floor.
    static func confidentText(from result: OCRService.Result) -> String? {
        let kept = result.blocks
            .filter { $0.confidence >= partialConfidenceFloor }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "\n")
    }

    /// The function result offering a partial transcription from a picture that was not good enough
    /// to read whole.
    ///
    /// Labelled as partial in the directive *and* in the sentence the model is told to lead with,
    /// because the failure being guarded against is a model receiving five legible words and
    /// presenting them as the label.
    static func partialTranscription(_ text: String,
                                     quality: CaptureQualityReport.Quality) -> String {
        let why = quality == .tooDark ? "too dark" : "too blurry"
        return """
            The photo was \(why) to read in full. On-device text recognition read only the lines \
            below with confidence. Read them to the user as a PARTIAL reading, saying first that \
            this is only the part that was legible and that the rest could not be read. Do NOT \
            complete, correct or extend them, and never supply a character, digit, name, date or \
            instruction that is not in this text. Offer to try again with the item held steady.

            PARTIAL TEXT (verbatim, on-device):
            \(text)
            """
    }
}
