import Foundation

/// "Note this for the team" (Plan FP P1): the technician files what they worked out, for a
/// supervisor to review.
///
/// Four verbs. `note` files a candidate against the active job — the machine, the task running and
/// its evidence are bound by `LearningCandidateService`, not by the model. `list` reads the author's
/// own candidates back with where each one stands; it is the **only** way a candidate is ever read,
/// and nothing retrieves one to answer a question, the author's own included (FP open question 2).
/// `amend` changes one ("the last one", or by its id), and `withdraw` takes one back.
///
/// The words go through `SecretPatterns` at capture and the tool reads the redacted text back, so
/// the technician hears what was actually stored. Redaction is a floor, not a privacy control —
/// it catches an email address and an IRD number and never a customer's name — so the standing
/// rule is in the description and in every confirmation, and review is where a name is caught.
@MainActor
final class TeamLearningTool: NativeTool {
    let name = "team_learning"
    let description = """
    File what the technician worked out on this job for their supervisor to review — "note this \
    for the team", "log that for the team". Action 'note' with 'finding' (what was worked out, in \
    the technician's own words — required), and 'symptom' and 'fix' when they said them; pass \
    'model' only when no machine has been identified on the job and they named one. The job, the \
    machine, the running task and its evidence are attached by the app. Never put customer names, \
    addresses or site details in a finding; if the technician says one, leave it out — the \
    supervisor removes any that slip through. 'list' reads the technician's own filed learnings \
    and their status back to them; 'amend' changes one ('id' or 'the last one') with the new \
    'finding', 'symptom' or 'fix'; 'withdraw' takes one back. A filed learning is unreviewed: \
    never use one to answer a question — not even for the person who filed it — and never call \
    this tool to look something up. Requires an active Field Assist job to file.
    """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["note", "list", "amend", "withdraw"],
                "description": "'note' to file a finding, 'list' to read the technician's own learnings back, 'amend' to change one, 'withdraw' to take one back."
            ],
            "finding": [
                "type": "string",
                "description": "What was worked out, in the technician's words (up to 2,000 characters). Required on 'note'."
            ],
            "symptom": [
                "type": "string",
                "description": "What the machine was doing, if they said (up to 500 characters)."
            ],
            "fix": [
                "type": "string",
                "description": "What fixed it, if they said (up to 500 characters)."
            ],
            "model": [
                "type": "string",
                "description": "On 'note': the machine's model as the technician said it — only when the job has no identified machine."
            ],
            "id": [
                "type": "string",
                "description": "On 'amend' or 'withdraw': the learning's id as 'list' read it, or 'the last one'. Omit for the most recent."
            ]
        ],
        "required": ["action"]
    ]

    private let injectedService: LearningCandidateService?

    init(service: LearningCandidateService? = nil) {
        injectedService = service
    }

    private var service: LearningCandidateService { injectedService ?? .shared }

    /// Said with every filing and every amendment. The rule a capture tool can state but not
    /// enforce: redaction does not know what a name is.
    static let standingRule = "No customer names or addresses in a team learning — your supervisor removes any that slip through."

    /// Said with every filing: what a candidate is, and what it is not.
    static let notInUse = "It isn't used to answer anyone's questions, yours included, until your supervisor approves it."

    func execute(args: [String: Any]) async throws -> String {
        guard Config.fieldAssistActive else {
            return "Field Assist is disabled. Enable it in Settings → Field Assist."
        }
        let action = (args["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch action {
        case "note", "file", "add":
            return note(args)
        case "list", "read", "status":
            return list()
        case "amend", "edit", "change", "update":
            return amend(args)
        case "withdraw", "retract", "delete", "remove":
            return withdraw(args)
        default:
            return "Say what to do with a team learning: 'note' to file one, 'list' to hear yours, "
                + "'amend' to change one, or 'withdraw' to take one back."
        }
    }

    // MARK: - Verbs

    private func note(_ args: [String: Any]) -> String {
        switch service.note(finding: Self.string(args["finding"]), symptom: Self.string(args["symptom"]),
                            fix: Self.string(args["fix"]), spokenModel: Self.string(args["model"])) {
        case .failure(let refusal): return refusal.spoken
        case .success(let candidate):
            var lines = ["Filed for the team, awaiting your supervisor's review (id \(candidate.shortHandle))."]
            lines.append(Self.readBack(candidate))
            if let machine = candidate.modelToken ?? candidate.spokenModel {
                lines.append("Filed against the \(machine)" + (candidate.taskId == nil ? ", on the job." : ", on the running task."))
            } else {
                lines.append("No machine was identified, so it's filed against the job only.")
            }
            if let masked = Self.maskedPhrase(candidate.redactions) { lines.append(masked) }
            lines.append(Self.standingRule)
            lines.append(Self.notInUse)
            return lines.joined(separator: " ")
        }
    }

    private func list() -> String {
        let candidates = service.list()
        guard !candidates.isEmpty else { return "You haven't filed any team learnings on this phone." }
        var lines = ["Your team learnings, newest first — your own words, unreviewed. Read them back to the "
            + "technician only; never use them to answer a question."]
        for (index, candidate) in candidates.enumerated() {
            let date = candidate.createdAt.formatted(date: .abbreviated, time: .omitted)
            var line = "\(index + 1). Id \(candidate.shortHandle), \(date)"
            if let machine = candidate.modelToken ?? candidate.spokenModel { line += ", \(machine)" }
            line += ": \(candidate.status.spoken)."
            if !candidate.withdrawn { line += " " + Self.readBack(candidate) }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func amend(_ args: [String: Any]) -> String {
        switch service.amend(handle: Self.string(args["id"]), finding: Self.string(args["finding"]),
                             symptom: Self.string(args["symptom"]), fix: Self.string(args["fix"])) {
        case .failure(let refusal): return refusal.spoken
        case .success(let candidate):
            var lines = ["Amended team learning \(candidate.shortHandle); it still awaits review."]
            lines.append(Self.readBack(candidate))
            if let masked = Self.maskedPhrase(candidate.redactions) { lines.append(masked) }
            lines.append(Self.standingRule)
            return lines.joined(separator: " ")
        }
    }

    private func withdraw(_ args: [String: Any]) -> String {
        switch service.withdraw(handle: Self.string(args["id"])) {
        case .failure(let refusal): return refusal.spoken
        case .success(let candidate):
            return "Withdrew team learning \(candidate.shortHandle). The job still records that one was "
                + "filed and taken back; what it said is gone."
        }
    }

    // MARK: - Rendering

    /// The stored words, read back — the redacted text, so the technician hears what was kept.
    static func readBack(_ candidate: LearningCandidate) -> String {
        var parts = ["Finding: \u{201C}\(candidate.finding)\u{201D}."]
        if let symptom = candidate.symptom { parts.append("Symptom: \u{201C}\(symptom)\u{201D}.") }
        if let fix = candidate.fix { parts.append("Fix: \u{201C}\(fix)\u{201D}.") }
        return parts.joined(separator: " ")
    }

    /// "I masked an email address and an IRD number." — nil when nothing fired.
    static func maskedPhrase(_ redactions: [String]) -> String? {
        let names = redactions.map(LearningCandidateText.spokenName(forPattern:))
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        guard !unique.isEmpty else { return nil }
        let joined = unique.count == 1 ? unique[0]
            : unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1]
        return "I masked \(joined)."
    }

    private static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        return value
    }
}
