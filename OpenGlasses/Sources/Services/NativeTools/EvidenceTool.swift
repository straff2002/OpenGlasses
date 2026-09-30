import Foundation

/// "Leave that photo out" — the technician's choice about the job's evidence, by voice (Plan GB P3).
///
/// The same choice the thumbnail's tick makes on the Job tab, and honoured the same way: a decided
/// item goes, or does not go, with the report whether or not the close review ever happens.
@MainActor
final class EvidenceTool: NativeTool {
    let name = "evidence"
    let description = """
    Choose which of the open job's photos and clips go with its report. 'exclude' or 'include' with \
    'item' 'latest' (the default) or an item id: "leave that photo out", "put the last picture \
    back". 'keep' records that the technician wants them sent as they are, 'include_all' and \
    'exclude_all' do what they say. The choice is kept whether or not the close review happens. \
    Requires an active session.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["exclude", "include", "keep", "include_all", "exclude_all"],
                "description": "What the technician decided."
            ],
            "item": [
                "type": "string",
                "description": "'latest' (default) or the id of one photo or clip."
            ]
        ],
        "required": ["action"]
    ]

    private let injectedSession: FieldSessionService?

    init(sessionService: FieldSessionService? = nil) {
        self.injectedSession = sessionService
    }

    private var session: FieldSessionService { injectedSession ?? .shared }

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        guard session.isOpenForEvidence else {
            return "No open Field Assist job, so there is no evidence to choose."
        }
        guard !session.jobMedia.isEmpty else { return "There are no photos or clips on this job." }
        let item = (args["item"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = (item == nil || item?.isEmpty == true || item?.lowercased() == "latest") ? nil : item
        switch (args["action"] as? String)?.lowercased() {
        case "exclude", "include":
            let include = (args["action"] as? String)?.lowercased() == "include"
            guard let decided = session.decideEvidence(itemId: itemId, included: include) else {
                return "No photo or clip with id '\(item ?? "")' on this job."
            }
            let what = decided.kind == .clip ? "clip" : "photo"
            return include ? "That \(what) goes with the report." : "That \(what) is left out of the report."
        case "keep":
            session.decideAllEvidence(included: nil)
            return "The photos and clips go as they are."
        case "include_all":
            session.decideAllEvidence(included: true)
            return "Every photo and clip goes with the report."
        case "exclude_all":
            session.decideAllEvidence(included: false)
            return "No photos or clips go with the report."
        default:
            return "Say which: exclude, include, keep, include_all or exclude_all."
        }
    }
}
