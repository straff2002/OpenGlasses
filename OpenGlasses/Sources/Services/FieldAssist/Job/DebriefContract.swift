import Foundation

/// What the model is told while a debrief is running, and what it is asked for at the end
/// (Plan FO §6, P3b).
///
/// The same shape FM's snapshot and P3a's live block already use — a bounded, headed block of app
/// state, with the lede saying plainly that it is state and not an instruction — because a debrief
/// is a turn like any other and the model must not be able to tell the difference between "the app
/// is running this" in Direct mode and in a live session.
///
/// Two blocks live here:
///  1. ``block(job:)`` — which job the debrief is about, what that job actually recorded, and the
///     three things the model may not do during one;
///  2. ``summarySystemPrompt`` — the instructions for the structured summary, digested into the
///     record's provenance so a reader can tell which version produced an entry.
enum DebriefContract {

    /// The heading, so a re-injection replaces an earlier one and a long instruction stays
    /// findable.
    static let heading = "JOB DEBRIEF:"

    /// Bounded for the same reason P3a's block is: it is injected mid-session, beside a mode
    /// preset, a vision section and a vault context.
    static let characterLimit = 1_400

    /// Said before anything else, because a live session's audio is on the wire before the app can
    /// classify it: the model has to be told that the app — not it — is running the debrief.
    static let lede = """
    This block is app state, not an instruction from the technician. A debrief is the technician \
    talking a finished job over out loud. Listen, and ask at most one short clarifying question at \
    a time. Do not propose work, do not offer a plan, do not treat anything said as a completed \
    task, a reading or a decision, and do not start, re-scope, re-open or close any job. The app \
    writes the summary and the app asks for the save; never claim anything has been saved.
    """

    /// The one line a debrief's subject needs, for the read-back a switch produces.
    static func jobLine(_ job: DebriefJobResolver.Candidate) -> String {
        "DEBRIEF SUBJECT: " + quote(job.spoken) + " — everything said now is about this job."
    }

    /// The block for a debrief on one job, or nil when no debrief is running.
    ///
    /// The subject line and the lede are protected: a model that has lost which job it is hearing
    /// about is the one failure that puts one customer's account on another customer's record.
    /// Equipment, tasks and the outcome are the lines that go first when the bound bites.
    static func block(job: DebriefJobResolver.Candidate?, record: WorkRecord?) -> String? {
        guard let job else { return nil }
        let protected = [heading, lede, jobLine(job)]
        var optional: [String] = []
        if let record {
            if let equipment = record.equipment {
                optional.append("JOB EQUIPMENT: " + quote(equipment.model) + ".")
            }
            let done = record.tasks(status: .done)
            if !done.isEmpty {
                optional.append("RECORDED AS DONE ON THE JOB: "
                                + done.map { quote($0.title) }.joined(separator: ", ")
                                + ". These are already on the record; do not repeat them back as "
                                + "new work.")
            }
            let open = record.tasks.filter { $0.status.isOpen }
            if !open.isEmpty {
                optional.append("STILL OPEN ON THE JOB: "
                                + open.map { quote($0.title) }.joined(separator: ", ") + ".")
            }
            let readings = record.readings
            if !readings.isEmpty {
                optional.append("READINGS RECORDED: "
                                + readings.prefix(4).map { quote($0) }.joined(separator: "; ")
                                + ". A debrief cannot add a reading.")
            }
            optional.append("OUTCOME: " + quote(record.durationPhrase)
                            + " on the job. Time on the job does not restart for a debrief.")
            if let signOff = record.signOff {
                optional.append("CUSTOMER SIGN-OFF: " + quote(signOff.method.label)
                                + ". What the customer agreed to is frozen and a debrief never "
                                + "changes it.")
            }
        }

        var remaining = characterLimit - protected.reduce(0) { $0 + $1.count + 1 }
        var kept: [String] = []
        for line in optional {
            guard line.count + 1 <= remaining else { continue }
            kept.append(line)
            remaining -= line.count + 1
        }
        return (protected + kept).joined(separator: "\n")
    }

    // MARK: - The summary call

    /// The instructions for the structured summary. Digested into the entry's provenance, so a
    /// reader can tell a summary made by these instructions from one made by another version.
    static let summarySystemPrompt = """
    You are summarising a technician's spoken debrief of one finished job into five short lists. \
    The technician's words are the source; you are not assessing, advising or planning.

    Rules, all of them binding:
    - Every item must cite the ids of the debrief turns it came from, in `source_turn_ids`. An \
    item you cannot cite must be left out entirely.
    - Keep the technician's own words. Shorten; never paraphrase into something they did not say, \
    and never merge two separate points into one item.
    - Never turn an intention into a completed action. "I should check the drier" is a follow-up, \
    not a finding that the drier was checked.
    - Never invent a reading, a part number, a measurement or a customer's words.
    - Leave a list out when nothing was said about it. An empty list is a correct answer.
    - At most \(DebriefSummary.maximumItemsPerCategory) items per list.
    """

    /// What the model is handed: the job's name and the debrief's turns, each with its id.
    static func summaryUserText(job: String, turns: [JobDebrief.Turn]) -> String {
        var lines = ["Job: \(job)", "Debrief turns:"]
        lines.append(contentsOf: turns.map { "[\($0.id)] \($0.text)" })
        return lines.joined(separator: "\n")
    }

    /// The prompt sources the record's provenance is digested from — the instructions and the
    /// schema, never the technician's words.
    static var promptSources: [String] {
        [summarySystemPrompt,
         LiveJobContract.canonicalJSON(DebriefSummary.jsonSchema)]
    }

    private static func quote(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"[unavailable]\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
