import Foundation

/// The visit's manual pages and job-level evidence, rolled up once (Plan GB P0).
///
/// Job 1011's report said "Against the job itself: 1 photo, **5** pages verified" and then listed
/// **six** pages: the count was taken over the job's own evidence, the list over the job's and
/// every task's, deduplicated. Both statements were true of their own set, and together they read
/// as a record that cannot count. Here the list is built once, and every sentence about pages is
/// read off it — the job-level phrase leaves pages to the list rather than counting a subset.
///
/// Pure: built from the record's own values.
struct EvidenceRollup: Equatable {

    /// Every page verified during the visit, task-attached or not, deduplicated, in the order the
    /// record has always listed them (the tasks' pages, then the job's).
    let verifiedPages: [String]

    /// "1 reading, 2 photos, 1 citation opened" for the evidence recorded against the job itself,
    /// with pages left to `verifiedPages`. Nil when there is nothing to say.
    let jobPhrase: String?

    init(tasks: [FieldSession.Task], jobEvidence: FieldSession.Evidence) {
        var seen = Set<String>()
        let all = tasks.flatMap(\.evidence.pagesVerified) + jobEvidence.pagesVerified
        verifiedPages = all.filter { seen.insert($0).inserted }

        var jobOnly = jobEvidence
        jobOnly.pagesVerified = []
        jobPhrase = WorkRecord.evidencePhrase(jobOnly)
    }
}
