import Foundation

/// How a bundle's contents meet what a phone already holds (Plan FP §4, P3) — pure, so every rule
/// below is a test and two phones that apply the same bundles end the same whatever the order.
///
/// - **Candidates** match on `candidateID`; a higher `revision` replaces a lower one. A candidate
///   the reviewer has already decided (approved, merged, not taken up) keeps its decision — a later
///   revision does not reopen it. A candidate this phone filed itself is never overwritten by a
///   copy of it. Arriving is not approval: an imported candidate is `received`, origin kept, with
///   an `importedFrom` note, and goes through `LearningReview` like a local one.
/// - **Duplicates surface, they are not merged.** A candidate whose subject and normalised finding
///   (P2's `LearningReview.normalisedFinding`) match another's is reported as a merge suggestion
///   for the reviewer; both are kept. Whether two findings say the same is the reviewer's call.
/// - **Entries** match on `entryID`; the later `approvedAt` wins. At the same `approvedAt` the job
///   lists are joined (a merge at the office raises the count without moving the approval time) and
///   any text difference is settled by a fixed ordering of the wire form, so no tie depends on
///   which bundle arrived first.
/// - **A tombstone beats content whatever its timestamp.** A retraction for an entry the phone holds
///   stamps it (kept as history, gone from retrieval); one for an entry it does not hold is kept as
///   a tombstone, so the content arriving later — in an older bundle — is stored already retracted.
///   Two retractions of one entry keep the earlier stamp.
/// - **A status is final once applied.** `approved`, `merged` and `not_taken_up` are applied once
///   and a replay is a no-op; `received` moves a candidate on only from `filed` or `sent`, and only
///   for the revision the phone holds.
/// - **A `decisions` bundle is a delta, not a whole set.** Nothing absent from it is removed — the
///   difference from the office's learning set (contract §6), which replaces the namespace whole.
///   Unsigned bundles arrive by hand, out of order and from more than one reviewer, so "absent"
///   cannot mean "withdrawn"; only a retraction withdraws. Applying the same bundle twice changes
///   nothing the second time.
enum LearningBundleMerge {

    /// What a phone holds that a bundle can change.
    struct Holdings: Equatable {
        var candidates: [LearningCandidate]
        var entries: [LearningEntry]
        /// Retractions for entries this phone does not hold (yet).
        var tombstones: [LearningBundle.Retraction]

        init(candidates: [LearningCandidate] = [], entries: [LearningEntry] = [],
             tombstones: [LearningBundle.Retraction] = []) {
            self.candidates = candidates
            self.entries = entries
            self.tombstones = tombstones
        }
    }

    /// Two candidates that probably say the same thing.
    struct DuplicatePair: Equatable, Hashable {
        let first: String
        let second: String

        init(_ a: String, _ b: String) {
            first = min(a, b)
            second = max(a, b)
        }
    }

    /// What applying a bundle did.
    struct Report: Equatable {
        var candidatesAdded: [String] = []
        var candidatesReplaced: [String] = []
        var candidatesUnchanged: [String] = []
        /// Arrived for a candidate already decided here; the decision stands.
        var candidatesKeptDecided: [String] = []
        /// Candidates that probably repeat one another — for the reviewer, never auto-merged.
        var duplicates: [DuplicatePair] = []
        /// Candidates that probably repeat a live entry, by candidate id (P2's suggestion).
        var entrySuggestions: [String: [String]] = [:]
        /// Entries whose stored record changed — published, updated, superseded or retracted —
        /// and so whose corpus documents must be brought in line.
        var entriesChanged: [String] = []
        var statusesApplied: [String] = []
        var statusesIgnored: [String] = []

        var changedAnything: Bool {
            !candidatesAdded.isEmpty || !candidatesReplaced.isEmpty || !entriesChanged.isEmpty
                || !statusesApplied.isEmpty
        }
    }

    /// Apply a whole bundle.
    static func apply(_ bundle: LearningBundle, to holdings: Holdings,
                      importedFrom note: String) -> (Holdings, Report) {
        var held = holdings
        var report = Report()
        mergeCandidates(bundle.candidates, into: &held, note: note, report: &report)
        mergeEntries(bundle.entries, retracted: bundle.retracted, into: &held, report: &report)
        mergeStatuses(bundle.statuses, into: &held, report: &report)
        return (held, report)
    }

    /// The note an imported candidate carries. Deterministic, so the same candidate from the same
    /// organisation carries the same note whichever bundle brought it.
    static func importNote(for bundle: LearningBundle) -> String {
        bundle.organisationLabel.map { "team-learning bundle from \($0)" } ?? "team-learning bundle"
    }

    // MARK: - Candidates

    static func mergeCandidates(_ incoming: [LearningBundle.Candidate], into held: inout Holdings,
                                note: String, report: inout Report) {
        var touched: [String] = []
        for wire in incoming {
            let arriving = wire.candidate(importedFrom: note)
            if let index = held.candidates.firstIndex(where: { $0.id == arriving.id }) {
                let existing = held.candidates[index]
                if existing.isLocal {
                    report.candidatesUnchanged.append(arriving.id)
                } else if isDecided(existing.status) {
                    report.candidatesKeptDecided.append(arriving.id)
                } else if arriving.revision > existing.revision {
                    var replacement = arriving
                    replacement.importedFrom = existing.importedFrom ?? note
                    held.candidates[index] = replacement
                    report.candidatesReplaced.append(arriving.id)
                    touched.append(arriving.id)
                } else {
                    report.candidatesUnchanged.append(arriving.id)
                }
            } else {
                held.candidates.append(arriving)
                report.candidatesAdded.append(arriving.id)
                touched.append(arriving.id)
            }
        }
        // Duplicates among everything held, for every candidate this bundle brought or changed.
        var pairs = Set<DuplicatePair>()
        for id in touched {
            guard let candidate = held.candidates.first(where: { $0.id == id }), !candidate.withdrawn,
                  let subject = LearningReview.defaultSubject(of: candidate) else { continue }
            let finding = LearningReview.normalisedFinding(candidate.finding)
            guard !finding.isEmpty else { continue }
            for other in held.candidates where other.id != id && !other.withdrawn {
                guard let otherSubject = LearningReview.defaultSubject(of: other),
                      LearningReview.sameSubject(subject, otherSubject),
                      LearningReview.normalisedFinding(other.finding) == finding else { continue }
                pairs.insert(DuplicatePair(id, other.id))
            }
            let suggestions = LearningReview.mergeSuggestions(for: candidate, among: held.entries)
            if !suggestions.isEmpty { report.entrySuggestions[id] = suggestions }
        }
        report.duplicates = pairs.sorted { ($0.first, $0.second) < ($1.first, $1.second) }
    }

    static func isDecided(_ status: LearningCandidate.Status) -> Bool {
        status == .approved || status == .merged || status == .notTakenUp
    }

    // MARK: - Entries and tombstones

    static func mergeEntries(_ incoming: [LearningBundle.Entry], retracted: [LearningBundle.Retraction],
                             into held: inout Holdings, report: inout Report) {
        let before = Dictionary(held.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for wire in incoming {
            let arriving = wire.entry()
            if let index = held.entries.firstIndex(where: { $0.id == arriving.id }) {
                held.entries[index] = merged(held.entries[index], with: arriving)
            } else {
                held.entries.append(arriving)
            }
        }

        // Every retraction known — held tombstones and the bundle's — reduced to the earliest per
        // entry, then stamped onto held entries; the rest stay tombstones.
        var earliest: [String: LearningBundle.Retraction] = [:]
        for retraction in held.tombstones + retracted {
            if let known = earliest[retraction.entryID], !precedes(retraction, known) { continue }
            earliest[retraction.entryID] = retraction
        }
        var tombstones: [LearningBundle.Retraction] = []
        for (entryID, retraction) in earliest {
            if let index = held.entries.firstIndex(where: { $0.id == entryID }) {
                held.entries[index] = stamped(held.entries[index], with: retraction)
            } else {
                tombstones.append(retraction)
            }
        }
        held.tombstones = tombstones.sorted { $0.entryID < $1.entryID }

        // An arriving entry that supersedes another takes it out of service here too, stamped at
        // the replacement's approval time so every phone stamps the same moment.
        for index in held.entries.indices where held.entries[index].supersededBy == nil {
            let id = held.entries[index].id
            // Any successor, live or since retracted: whether one was retracted must not depend on
            // which bundle arrived first, or two phones would disagree about the entry it replaced.
            let successors = held.entries.filter { $0.supersedes == id && $0.id != id }
            guard let first = successors.min(by: { ($0.approvedAt, $0.id) < ($1.approvedAt, $1.id) }) else { continue }
            held.entries[index].supersededBy = first.id
            held.entries[index].supersededAt = held.entries[index].supersededAt ?? first.approvedAt
        }

        for entry in held.entries where before[entry.id] != entry {
            report.entriesChanged.append(entry.id)
        }
    }

    /// The held entry after an arriving copy: the later approval wins; at the same approval time
    /// the job lists join and the text is settled by a fixed order. The phone's own history —
    /// approver's name, the captured text, supersession and retraction stamps — is kept.
    static func merged(_ held: LearningEntry, with arriving: LearningEntry) -> LearningEntry {
        if arriving.approvedAt < held.approvedAt { return held }
        var result = held
        if arriving.approvedAt > held.approvedAt {
            result = replacingWireFields(of: held, with: arriving)
        } else {
            if wireKey(arriving) > wireKey(held) { result = replacingWireFields(of: held, with: arriving) }
            // Same approval: a merge at the office raised the count without moving the time, so
            // differing job lists join and the larger count stands — the same answer in either order.
            let heldJobs = held.sourceJobIDs ?? [], arrivingJobs = arriving.sourceJobIDs ?? []
            if Set(heldJobs) != Set(arrivingJobs) {
                let jobs = Array(Set(heldJobs + arrivingJobs)).sorted()
                result.sourceJobIDs = jobs.isEmpty ? nil : jobs
            }
            if held.confirmedJobCount != arriving.confirmedJobCount || Set(heldJobs) != Set(arrivingJobs) {
                let top = [held.confirmedJobCount, arriving.confirmedJobCount].compactMap { $0 }.max()
                result.confirmedJobCount = max(top ?? 0, result.sourceJobIDs?.count ?? 0)
            }
        }
        return result
    }

    private static func replacingWireFields(of held: LearningEntry, with arriving: LearningEntry) -> LearningEntry {
        var result = LearningEntry(
            id: held.id, subject: arriving.subject, vaultIDs: arriving.vaultIDs, finding: arriving.finding,
            symptom: arriving.symptom, fix: arriving.fix, approvedAt: arriving.approvedAt,
            approvedByRole: arriving.approvedByRole,
            approvedByName: arriving.approvedAt == held.approvedAt ? held.approvedByName : arriving.approvedByName,
            authorIsApprover: arriving.authorIsApprover, contradictsSafetyNote: arriving.contradictsSafetyNote,
            supersedes: arriving.supersedes, candidateID: arriving.candidateID, origin: arriving.origin,
            sourceJobIDs: arriving.sourceJobIDs, confirmedJobCount: arriving.confirmedJobCount,
            captured: arriving.approvedAt == held.approvedAt ? held.captured : nil)
        result.supersededAt = held.supersededAt
        result.supersededBy = held.supersededBy
        result.retractedAt = held.retractedAt
        result.retractionReason = held.retractionReason
        return result
    }

    /// The wire form's text, for a deterministic tie-break. Job lists are left out: they join.
    private static func wireKey(_ entry: LearningEntry) -> String {
        var wire = LearningBundle.Entry(entry)
        wire.sourceJobIDs = nil
        wire.confirmedJobCount = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(wire)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The earlier retraction; at the same second, the lesser reason — any fixed rule will do.
    static func precedes(_ a: LearningBundle.Retraction, _ b: LearningBundle.Retraction) -> Bool {
        (a.retractedAt, a.reason) < (b.retractedAt, b.reason)
    }

    static func stamped(_ entry: LearningEntry, with retraction: LearningBundle.Retraction) -> LearningEntry {
        var result = entry
        if let at = entry.retractedAt {
            let held = LearningBundle.Retraction(entryID: entry.id,
                                                 retractedAt: Int64(at.timeIntervalSince1970.rounded(.down)),
                                                 reason: entry.retractionReason ?? "")
            guard precedes(retraction, held) else { return entry }
        }
        result.retractedAt = retraction.retractedDate
        result.retractionReason = retraction.reason
        return result
    }

    // MARK: - Statuses

    static func mergeStatuses(_ incoming: [LearningBundle.Status], into held: inout Holdings,
                              report: inout Report) {
        for status in incoming {
            guard let index = held.candidates.firstIndex(where: { $0.id == status.candidateID }) else {
                report.statusesIgnored.append(status.candidateID)
                continue
            }
            let candidate = held.candidates[index]
            guard let next = applying(status, to: candidate) else {
                report.statusesIgnored.append(status.candidateID)
                continue
            }
            held.candidates[index] = next
            report.statusesApplied.append(status.candidateID)
        }
    }

    /// The candidate after a status, or nil when it changes nothing: a withdrawn candidate, one
    /// already decided (a replay), a `received` for a revision older than the one held, or a
    /// `received` for a candidate already past it.
    static func applying(_ status: LearningBundle.Status, to candidate: LearningCandidate) -> LearningCandidate? {
        guard !candidate.withdrawn, !isDecided(candidate.status) else { return nil }
        var next = candidate
        switch status.status {
        case .received:
            guard candidate.status == .filed || candidate.status == .sent,
                  status.revision >= Int64(candidate.revision) else { return nil }
            next.status = .received
        case .approved, .merged:
            next.status = status.status.candidateStatus
            next.entryID = status.entryID
        case .notTakenUp:
            next.status = .notTakenUp
            next.reviewReason = status.reason
        }
        next.updatedAt = Date(timeIntervalSince1970: TimeInterval(status.issuedAt))
        return next
    }
}

extension LearningBundle {

    /// The part of a bundle a person accepted: the entries and retractions named, and the statuses
    /// for the candidates named.
    func selecting(entryIDs: Set<String>, candidateIDs: Set<String>) -> LearningBundle {
        var out = self
        out.candidates = candidates.filter { candidateIDs.contains($0.candidateID) }
        out.statuses = statuses.filter { candidateIDs.contains($0.candidateID) }
        out.entries = entries.filter { entryIDs.contains($0.entryID) }
        out.retracted = retracted.filter { entryIDs.contains($0.entryID) }
        return out
    }
}
