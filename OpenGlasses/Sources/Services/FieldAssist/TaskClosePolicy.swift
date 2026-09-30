import Foundation

/// A check that has to pass before a fix counts as a fix (Plan GB P3).
///
/// Job 1011's clear-and-retest procedure reached its last step — "run a full heat cycle … only
/// after the retest passes" — and the job was recorded as resolved on the spot, the instruction
/// never shown, the retest never done. A fault that needs a retest is not resolved until the
/// retest passes, and the record has to be able to say "fixed, not yet verified".
struct VerificationRequirement: Codable, Equatable {
    /// What has to be done and seen, in the vault's words.
    let instruction: String
    /// The procedure step it came from, when a procedure set it.
    var procedureStepId: String?
    /// When the technician confirmed it. Nil while it is still owed.
    var verifiedAt: Date?

    init(instruction: String, procedureStepId: String? = nil, verifiedAt: Date? = nil) {
        self.instruction = instruction
        self.procedureStepId = procedureStepId
        self.verifiedAt = verifiedAt
    }

    var isVerified: Bool { verifiedAt != nil }

    /// The open task's title: "Verify: run a full heat cycle".
    var taskTitle: String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = trimmed.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? trimmed
        let short = firstSentence.count > 90 ? String(firstSentence.prefix(87)) + "…" : firstSentence
        guard let first = short.first else { return "Verify" }
        return "Verify: " + first.lowercased() + short.dropFirst()
    }

    /// What every tool result says while a verification is owed, so the model cannot talk a
    /// half-finished fix into a resolved one.
    static let notYetVerified = "Not yet verified. Do not say resolved."
}

/// Whether a task may close, and what closing it leaves behind (Plan GB P3).
///
/// Pure: the task and whether the technician confirmed are the inputs.
enum TaskClosePolicy {

    enum Decision: Equatable {
        /// Close it as asked.
        case close
        /// Close the fix, and leave an open "Verify: …" task for the check still owed.
        case closeSpawningVerification(title: String)
        /// Do not close it; the sentence says why.
        case refuse(reason: String)
    }

    /// - Parameters:
    ///   - confirmed: the technician said the check passed.
    ///   - isVerificationTask: the task *is* the owed check — it can only close by passing it, or
    ///     be abandoned, never "done" unconfirmed.
    static func decide(task: FieldSession.Task, status: FieldSession.Task.Status,
                       confirmed: Bool) -> Decision {
        guard status == .done, let requirement = task.verification, !requirement.isVerified else {
            return .close
        }
        if confirmed { return .close }
        if task.isVerificationTask {
            return .refuse(reason: "'\(task.title)' is the check itself: it closes when the technician "
                           + "says it passed. \(VerificationRequirement.notYetVerified)")
        }
        return .closeSpawningVerification(title: requirement.taskTitle)
    }
}

extension FieldSession.Task {
    /// A task that exists only to hold an owed check.
    var isVerificationTask: Bool { verification != nil && title.hasPrefix("Verify:") }

    /// Owed and not yet confirmed.
    var awaitsVerification: Bool { status.isOpen && verification?.isVerified == false }
}

extension FieldSession {
    /// The checks still owed on this job — what keeps it from being recorded as resolved.
    var openVerifications: [Task] { tasks.filter(\.awaitsVerification) }
}
