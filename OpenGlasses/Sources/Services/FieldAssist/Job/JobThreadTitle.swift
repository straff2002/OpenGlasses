import Foundation

/// What a job's conversation is called in the Chat tab.
///
/// A saved thread is titled from its first sentence, which for a job is "Start a job on the
/// default vault" — an index entry that tells a technician nothing a week later. Once the number
/// is known the thread is the job, and it should say so.
///
/// The rule that matters is the one about *not* renaming: a title the technician chose is theirs.
/// Only the machine-generated ones are replaced — the placeholder, the store's own auto-title, and
/// a title this type produced earlier for the same job (so adding the equipment later works).
enum JobThreadTitle {

    /// The title for a job, or nil when there is not yet enough to say.
    ///
    /// The number leads because that is the thing the technician looks the job up by; the machine
    /// follows it when the session knows one. Without a number there is nothing to lead with, so
    /// the thread keeps whatever title it had — the number usually arrives a moment later.
    static func title(reference: String?, equipment: String?) -> String? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else { return nil }
        guard let equipment = equipment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !equipment.isEmpty else { return stem(reference) }
        return stem(reference) + separator + equipment
    }

    /// "Job 1005" — the part every title for this job starts with.
    static func stem(_ reference: String) -> String { "Job " + reference }

    static let separator = " — "

    /// Whether `existing` is a title this type produced for `reference`.
    static func isGenerated(_ existing: String, reference: String) -> Bool {
        let stem = stem(reference.trimmingCharacters(in: .whitespacesAndNewlines))
        return existing == stem || existing.hasPrefix(stem + separator)
    }
}
