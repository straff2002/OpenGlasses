import Foundation

/// Who a user-role line in a job's log came from (Plan GB P0).
///
/// Job 1011's transcript opened with "A Field Assist session has just been started… do not call
/// field_session start", attributed to the technician. The words were the app's: the Field Assist
/// quick action starts the job and then sends that instruction to the model through the ordinary
/// message path, which logs every user-role turn as something the technician said. A work order
/// that quotes the app instructing the model, under the technician's name, is a record that says
/// something nobody said.
enum TranscriptOrigin: String, Codable, Equatable {
    /// Something the technician said or typed.
    case technician
    /// An instruction the app sent to the model on the technician's behalf.
    case appInstruction = "app_instruction"
}

/// Recognises the app's own prompts by their exact text, so records saved before the origin was
/// tagged export without them.
///
/// **Exact match only.** A technician who happens to say something that resembles an instruction
/// is still the technician; the only lines treated as the app's are the ones the app is known to
/// have sent, word for word. Whitespace at the ends is ignored, nothing else is.
enum TranscriptOriginClassifier {

    /// Every prompt the app has sent as a user turn at the start of a job, current and past. A
    /// wording change adds a line here; none is ever removed, because saved records keep the old
    /// wording forever.
    static let knownAppPrompts: Set<String> = {
        var prompts: Set<String> = [
            // The Field Assist quick action's introduction before Plan FO P1 made the app start
            // the job itself.
            "Start a Field Assist session on my default vault. Briefly confirm you're ready and what you can help me troubleshoot.",
        ]
        if let current = QuickAction.fieldAssist.promptText { prompts.insert(current) }
        return prompts
    }()

    static func origin(of text: String) -> TranscriptOrigin {
        knownAppPrompts.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
            ? .appInstruction : .technician
    }

    /// The origin of a logged event: the app-instruction kind outright, a user message tagged with
    /// its origin, or — for a record written before either existed — the exact-match rule.
    static func origin(of event: SessionLogger.Event) -> TranscriptOrigin {
        if event.kind == .appInstruction { return .appInstruction }
        if let raw = event.payload?["origin"]?.value as? String,
           let tagged = TranscriptOrigin(rawValue: raw) {
            return tagged
        }
        return origin(of: event.text ?? "")
    }

    /// Whether a logged event is something the technician said. Every transcript reader asks this
    /// rather than testing the event kind, so none of them can quote the app as the technician.
    static func isTechnicianLine(_ event: SessionLogger.Event) -> Bool {
        event.kind == .userMessage && origin(of: event) == .technician
    }
}
