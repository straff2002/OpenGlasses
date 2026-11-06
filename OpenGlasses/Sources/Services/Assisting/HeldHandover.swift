import Foundation

/// A handover the expert's phone holds (Plan KM §7, P2): the latest generation, every generation
/// it has seen, what changed in the last one, the expert's clock and the reply.
///
/// **A copy, and read-only.** It is what the file said, kept apart from everything else on the
/// phone (`AssistingHandoverStore`). Nothing here can act on the technician's job: there is no
/// field that names their phone, and the only thing that leaves is the expert's own time reply.
struct HeldHandover: Codable, Equatable, Identifiable, Sendable {
    /// The latest generation opened.
    private(set) var handover: ExpertHandover
    /// Every generation opened, in order, once each. The reply carries all of them.
    private(set) var generationsSeen: [Int]
    let firstReceivedAt: Date
    private(set) var lastReceivedAt: Date
    /// What the latest generation changed from the one before, by section. Empty for the first.
    private(set) var changes: HandoverChanges
    /// Nil until Take this job.
    var clock: AssistingClock?
    /// When the expert's share of the time reply completed. Nil until it has.
    var replySentAt: Date?
    /// The coaching steps the expert is writing for this handover (Plan KM P3), kept as they write
    /// them so a relaunch loses none. Nil until the first step, and on every handover held before
    /// this existed.
    var coachingDraft: [CoachingStep]?
    /// The note for the time reply, as far as the expert has written it. Nil when empty.
    var noteDraft: String?
    /// When the expert's share of their coaching steps last completed. Nil until it has.
    var coachingSentAt: Date?
    /// The coaching replies whose share completed, by id, in order (Plan KM P4): the time reply
    /// names them, so the organisation can see one it never got. Nil until the first.
    var coachingRepliesSent: [String]?
    /// Calls this phone saw connect and end while this handover's clock ran (Plan KM P4): the time
    /// reply's call minutes. Nil when none was seen — the reply then carries no call minutes.
    var observedCalls: [AssistingObservedCall]?

    /// The observed calls' total, in whole minutes; nil when none was seen.
    var observedCallMinutes: Int? {
        guard let observedCalls, !observedCalls.isEmpty else { return nil }
        return AssistingClock.wholeMinutes(observedCalls.reduce(0) { $0 + $1.seconds })
    }

    var id: String { handover.handoverId }

    init(handover: ExpertHandover, receivedAt: Date) {
        self.handover = handover
        generationsSeen = [handover.generation]
        firstReceivedAt = receivedAt
        lastReceivedAt = receivedAt
        changes = .none
    }

    /// The organisation the handover is confidential to, as it groups the list. Empty when the
    /// sender's phone had no organisation name.
    var organisationName: String { handover.organisation.name }

    /// The key handovers are grouped by: one organisation at a time, never searched across.
    var organisationKey: String { HeldHandover.organisationKey(handover.organisation.name) }

    static func organisationKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A later generation of this handover replaces this one, and says what changed.
    mutating func replace(with newer: ExpertHandover, receivedAt: Date) {
        changes = HandoverChanges.between(handover, newer)
        handover = newer
        generationsSeen = Array(Set(generationsSeen + [newer.generation])).sorted()
        lastReceivedAt = receivedAt
    }

    // MARK: - Retention (§7)

    /// When the phone deletes it: the handover's own retention period after Done, or — for one
    /// never marked Done — after the last thing that happened to it, so a handover nobody took
    /// does not stay for ever.
    var expiresAt: Date {
        let days = ExpertHandoverRetention.range.contains(handover.retentionDays)
            ? handover.retentionDays : ExpertHandoverRetention.defaultDays
        let from = clock?.doneAt ?? max(lastReceivedAt, clock?.lastActivity ?? lastReceivedAt)
        return from.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

/// What a later generation changed (§3: "the expert's app replaces the earlier generation and
/// marks what changed"). Pure: two values in, sections and sentences out.
struct HandoverChanges: Codable, Equatable, Sendable {
    enum Section: String, Codable, CaseIterable, Sendable {
        case question, job, unit, tasks, procedures, readings, deviations, ruledOut, conversation, photos, manuals
    }

    let sections: [Section]
    /// "2 new readings", "The question changed", one per changed section.
    let lines: [String]

    static let none = HandoverChanges(sections: [], lines: [])

    var isEmpty: Bool { sections.isEmpty }

    func contains(_ section: Section) -> Bool { sections.contains(section) }

    static func between(_ old: ExpertHandover, _ new: ExpertHandover) -> HandoverChanges {
        var sections: [Section] = []
        var lines: [String] = []
        func note(_ section: Section, _ line: String) {
            sections.append(section)
            lines.append(line)
        }
        if old.question != new.question { note(.question, "The question changed.") }
        if old.job.reference != new.job.reference || old.job.faultReport != new.job.faultReport
            || old.job.site != new.job.site || old.job.trades != new.job.trades {
            note(.job, "The job details changed.")
        }
        if old.job.unit != new.job.unit { note(.unit, "The unit changed.") }
        if old.work.tasks != new.work.tasks { note(.tasks, counted(new.work.tasks.count - old.work.tasks.count, "task", "Tasks changed.")) }
        if old.work.procedures != new.work.procedures { note(.procedures, "Procedures changed.") }
        if old.work.readings != new.work.readings {
            note(.readings, counted(new.work.readings.count - old.work.readings.count, "reading", "Readings changed."))
        }
        if old.work.deviations != new.work.deviations { note(.deviations, "Deviations changed.") }
        if old.work.ruledOut != new.work.ruledOut { note(.ruledOut, "What's ruled out changed.") }
        if old.conversation != new.conversation {
            let added = new.conversation.lines.count - old.conversation.lines.count
            note(.conversation, added > 0
                 ? (added == 1 ? "1 new line in the conversation." : "\(added) new lines in the conversation.")
                 : "The conversation changed.")
        }
        if old.photos != new.photos || old.photosLeftOut != new.photosLeftOut {
            note(.photos, counted(new.photos.count - old.photos.count, "photo", "The photos changed."))
        }
        if old.manualReferences != new.manualReferences { note(.manuals, "Manual references changed.") }
        return HandoverChanges(sections: sections, lines: lines)
    }

    /// "2 new readings", "1 new task", or the fallback when the count did not grow.
    private static func counted(_ added: Int, _ noun: String, _ fallback: String) -> String {
        guard added > 0 else { return fallback }
        return added == 1 ? "1 new \(noun)." : "\(added) new \(noun)s."
    }
}
