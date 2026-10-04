import Foundation

/// What a person is told before a job is recorded, and the record that they were told
/// (Plan HE §5).
///
/// A recorded job holds the sound and the pictures of everybody who was there, unblurred, and it
/// leaves the phone for the organisation's office. Nothing records until the person holding the
/// phone has read that in plain words and said so. It is asked once, for the wording as it stands
/// and for the organisation the phone is paired with: a change to either asks again. Each start
/// after that shows one line.
///
/// Pure: the wording, and whether an acknowledgement still stands. Where the acknowledgement is
/// kept is the app's.
enum RecordingConsent {

    /// The wording's revision. Raised whenever a point below changes what the person is agreeing
    /// to, so an acknowledgement of the old words does not stand for the new ones.
    static let wordingVersion = 1

    static let title = "Before you record this job"

    /// What the button that acknowledges it says.
    static let acknowledgeTitle = "I understand — record this job"

    /// Shown each time a recording starts.
    static let reminder = "Recording this job for your office. Tell the people nearby."

    /// The points the sheet makes, in the order it makes them.
    static func points(limits: RetentionDecision.Limits = .standard) -> [String] {
        let days = max(1, Int((limits.trimAfterAcknowledgement / 86_400).rounded()))
        let kept = days == 1 ? "1 day" : "\(days) days"
        return [
            "Sound and pictures are recorded from the glasses for as long as the recording runs, including while you talk to the assistant.",
            "The assistant's replies may be heard on the recording.",
            "The recording goes to your organisation's office, and nowhere else. It can't be shared, saved to Photos or attached to a report from this phone.",
            "Faces are not blurred unless your organisation requires it. The face blur setting in this app does not change this recording.",
            "Tell the people nearby that you are recording.",
            "The recording stays on this phone until the office confirms it has it. Its video and sound are removed from the phone \(kept) after that.",
        ]
    }

    /// That a person read the points and said so.
    struct Acknowledgement: Equatable, Codable, Sendable {
        /// When they did. It goes into every bundle's manifest as `consentAt`.
        let at: Date
        let wordingVersion: Int
        /// The organisation the phone was paired with at the time: the office the words name.
        let organizationID: String

        init(at: Date, wordingVersion: Int = RecordingConsent.wordingVersion, organizationID: String) {
            self.at = at
            self.wordingVersion = wordingVersion
            self.organizationID = organizationID
        }
    }

    /// Whether an acknowledgement still stands: it was for these words, for this organisation, and
    /// was not given in the future. No acknowledgement, or an organisation that cannot be named,
    /// is no consent.
    static func stands(_ acknowledgement: Acknowledgement?, organizationID: String, now: Date) -> Bool {
        guard let acknowledgement, !organizationID.isEmpty else { return false }
        return acknowledgement.wordingVersion == wordingVersion
            && acknowledgement.organizationID == organizationID
            && acknowledgement.at <= now
    }
}
