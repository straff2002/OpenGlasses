import Foundation

/// This phone's finished jobs, indexed by where they were and what they were on (Plan FO §7, P3c).
///
/// Session history is a flat list sorted by start date; the brief needs "every earlier visit to
/// this site, or to this serial, or to this model". This is that index — pure, rebuilt from the
/// sessions it is handed, and **only** from them: it has no store, no network and no notion of
/// another device, so a visit another technician made on another phone can never appear in a brief
/// as though it happened here. What the crew as a whole has learned is FP's to bring, through the
/// brief's learnings seam, labelled as the crew's.
struct JobHistoryIndex: Equatable {

    /// One finished visit, reduced to what a brief can say about it.
    struct Visit: Equatable, Identifiable {
        let id: String
        let jobReference: String?
        let startedAt: Date
        let outcomeLabel: String
        /// Every model the visit was on, as recorded — current equipment first.
        let models: [String]
        let serials: [String]
        let siteKey: String?
        /// Titles of the tasks recorded as done.
        let workDone: [String]
        /// What was left for later: open or deferred tasks, and a saved debrief's follow-ups.
        let followUps: [String]
        /// What a saved debrief said was found, or wanted base to know.
        let debriefNotes: [String]

        /// "Job 0993, 14 May 2026" — or "A visit on 14 May 2026" when it had no number.
        var label: String {
            let date = startedAt.formatted(date: .abbreviated, time: .omitted)
            guard let jobReference else { return "A visit on \(date)" }
            return "Job \(jobReference), \(date)"
        }

        /// Where a brief line drawn from this visit says it came from.
        var citation: String { "\(label) — this phone's job history" }
    }

    /// Why a visit matched. A visit can match for several reasons; the strongest is kept.
    enum MatchReason: Int, Comparable {
        case serial = 0
        case site = 1
        case model = 2

        var phrase: String {
            switch self {
            case .serial: return "same serial"
            case .site: return "same site"
            case .model: return "same model"
            }
        }

        static func < (lhs: MatchReason, rhs: MatchReason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Match: Equatable {
        let visit: Visit
        let reason: MatchReason
    }

    /// Finished visits, newest first.
    let visits: [Visit]

    init(sessions: [FieldSession]) {
        visits = sessions
            .filter { $0.endedAt != nil && $0.outcome != .cancelled }
            .sorted { $0.startedAt > $1.startedAt }
            .map(Self.visit(for:))
    }

    // MARK: - Lookups

    func visits(site: JobSite?) -> [Visit] {
        guard let key = Self.siteKey(site) else { return [] }
        return visits.filter { $0.siteKey == key }
    }

    func visits(serial: String?) -> [Visit] {
        guard let wanted = Self.normalised(serial) else { return [] }
        return visits.filter { $0.serials.contains { Self.normalised($0) == wanted } }
    }

    func visits(model: String?) -> [Visit] {
        let wanted = Self.modelTokens(model)
        guard !wanted.isEmpty else { return [] }
        return visits.filter { visit in
            visit.models.contains { !Self.modelTokens($0).isDisjoint(with: wanted) }
        }
    }

    /// Everything relevant to a job ahead, newest first, each visit once with its strongest
    /// reason.
    func matches(for job: UpcomingJob) -> [Match] {
        var best: [String: Match] = [:]
        func consider(_ found: [Visit], _ reason: MatchReason) {
            for visit in found {
                if let existing = best[visit.id], existing.reason <= reason { continue }
                best[visit.id] = Match(visit: visit, reason: reason)
            }
        }
        consider(visits(site: job.site), .site)
        for unit in job.equipment {
            consider(visits(serial: unit.serial), .serial)
            consider(visits(model: unit.model), .model)
        }
        return best.values.sorted { $0.visit.startedAt > $1.visit.startedAt }
    }

    // MARK: - Keys

    /// The address when there is one, else the customer — lowercased, punctuation dropped, spaces
    /// collapsed. "14 Smith St." and "14 smith st" are one site; "14 Smith Street" is, honestly,
    /// not something a string comparison can decide, and the index does not pretend to.
    static func siteKey(_ site: JobSite?) -> String? {
        guard let site, let basis = site.address ?? site.customer else { return nil }
        let words = basis.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Uppercased letters and digits only, for serials.
    static func normalised(_ value: String?) -> String? {
        guard let value else { return nil }
        var result = ""
        for scalar in value.uppercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty ? nil : result
    }

    /// The model-like tokens in a model string, uppercased. Exact tokens only — "SLP99" does not
    /// match "SLP98" and a brief that said it did would be inventing history.
    static func modelTokens(_ model: String?) -> Set<String> {
        guard let model else { return [] }
        return Set(VaultModelIndex.modelLikeTokens(in: model).map { $0.uppercased() })
    }

    // MARK: - Building

    private static func visit(for session: FieldSession) -> Visit {
        var models: [String] = []
        for token in [session.equipment?.modelToken].compactMap({ $0 }) + session.visitedUnits.map(\.modelToken)
        where !models.contains(token) {
            models.append(token)
        }
        var serials: [String] = session.visitedUnits.compactMap(\.serial)
        for field in session.identityFields where field.name.lowercased().contains("serial") {
            serials.append(field.value)
        }

        let done = session.tasks.filter { $0.status == .done }.map(\.title)
        var followUps = session.tasks
            .filter { $0.status.isOpen || $0.status == .deferred }
            .map(\.title)
        var notes: [String] = []
        for debrief in session.debriefs {
            for entry in debrief.entries {
                switch entry.category {
                case DebriefSummary.Category.followUps.rawValue:
                    followUps.append(entry.text)
                case DebriefSummary.Category.findings.rawValue,
                     DebriefSummary.Category.forBase.rawValue:
                    notes.append(entry.line)
                default:
                    break
                }
            }
        }
        return Visit(id: session.id,
                     jobReference: session.jobReference.flatMap { $0.isEmpty ? nil : $0 },
                     startedAt: session.startedAt,
                     outcomeLabel: session.outcome.displayName,
                     models: models,
                     serials: serials,
                     siteKey: siteKey(session.site),
                     workDone: done,
                     followUps: followUps,
                     debriefNotes: notes)
    }
}
