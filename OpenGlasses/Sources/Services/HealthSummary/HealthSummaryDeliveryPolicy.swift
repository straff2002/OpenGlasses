import Foundation

/// Who hears a health summary: the model, or only the wearer.
///
/// Health numbers leave the phone only inside an answer to a question the wearer asked, and only to
/// an AI provider when they have said so. A tool result is the payload of the next model request,
/// so "returning the sentence" to a cloud model *is* sending it. When that is not allowed the tool
/// speaks the sentence itself, on-device voices only, and hands the model a receipt with no numbers
/// in it: the question reached the provider, the answer did not.
///
/// Apple guideline 5.1.3 is the other half of this: Health data may reach a third party only with
/// the wearer's explicit consent, which here is the existing, off-by-default share toggle.
enum HealthSummaryDeliveryPolicy {

    enum Delivery: Equatable {
        /// The sentence is the tool result; the model reads it and can answer follow-ups.
        case returnToModel
        /// The tool speaks the sentence and returns only `receipt`.
        case speakDirect
    }

    struct Inputs: Equatable {
        /// True only when every model the result could reach runs on this phone.
        var activeModelIsLocal: Bool
        var shareHealthWithAI: Bool
        var hipaaMode: Bool
        var medicalLocalOnly: Bool
    }

    /// Medical Compliance first: a clinic's mode means health numbers are not handed to a model at
    /// all, local or not, so the rule is the same whatever else is set. Then the model's location,
    /// then the wearer's consent.
    static func decide(_ inputs: Inputs) -> Delivery {
        if inputs.hipaaMode || inputs.medicalLocalOnly { return .speakDirect }
        if inputs.activeModelIsLocal { return .returnToModel }
        return inputs.shareHealthWithAI ? .returnToModel : .speakDirect
    }

    static func decide(activeModelIsLocal: Bool, shareHealthWithAI: Bool,
                       hipaaMode: Bool, medicalLocalOnly: Bool) -> Delivery {
        decide(Inputs(activeModelIsLocal: activeModelIsLocal, shareHealthWithAI: shareHealthWithAI,
                      hipaaMode: hipaaMode, medicalLocalOnly: medicalLocalOnly))
    }

    // MARK: - Receipts (the whole tool result on the speak-direct path)

    /// Returned after the wearer heard the summary. Content-free by construction: it is a constant.
    static let receipt =
        "The health summary was spoken to the wearer directly. Its values were withheld from you "
        + "by the wearer's Health privacy settings. Do not repeat, estimate or comment "
        + "on the numbers; reply with at most a brief acknowledgement."

    /// Returned when the summary could not be played (muted, silent mode, no audio route).
    static let notSpokenReceipt =
        "The health summary could not be spoken right now, and its values are withheld from you "
        + "by the wearer's Health privacy settings. Tell the wearer to ask again when "
        + "sound is on, or to open Avenkin's Health settings. Do not guess the numbers."
}
