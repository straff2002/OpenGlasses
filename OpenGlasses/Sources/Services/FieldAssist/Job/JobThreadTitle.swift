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
    ///
    /// A job with a name (Plan KR P6, owner decision 1) is "Job <reference> — <name>", or the
    /// name alone when it already starts with the reference ("1027 boiler swap"), so the number is
    /// never said twice. The name stands in for the machine: it is what the technician called the
    /// job. Without a name, the rule above, unchanged.
    static func title(reference: String?, name: String? = nil, equipment: String?) -> String? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else { return nil }
        if let named = named(reference: reference, name: name) { return named }
        guard let equipment = equipment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !equipment.isEmpty else { return stem(reference) }
        return stem(reference) + separator + equipment
    }

    /// The job's number and name as one label, or nil when there is no name: "Job 1027 — Boiler
    /// swap", or "1027 boiler swap" for a name that leads with the number (or with "Job 1027").
    static func named(reference: String, name: String?) -> String? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard !reference.isEmpty else { return name }
        if leads(name, with: reference) || leads(name, with: stem(reference)) { return name }
        return stem(reference) + separator + name
    }

    /// Whether `text` opens with `prefix` as a whole word, ignoring case: "1027 boiler" opens with
    /// "1027", "10275 boiler" does not.
    private static func leads(_ text: String, with prefix: String) -> Bool {
        guard let range = text.range(of: prefix, options: [.anchored, .caseInsensitive]) else { return false }
        guard range.upperBound < text.endIndex else { return true }
        let next = text[range.upperBound]
        return !(next.isLetter || next.isNumber)
    }

    /// "Job 1005" — the part every title for this job starts with.
    static func stem(_ reference: String) -> String { "Job " + reference }

    static let separator = " — "

    /// Whether `existing` is a title this type produced for `reference` — or, for a job with a
    /// name, the name-alone form of it.
    static func isGenerated(_ existing: String, reference: String, name: String? = nil) -> Bool {
        let stem = stem(reference.trimmingCharacters(in: .whitespacesAndNewlines))
        if existing == stem || existing.hasPrefix(stem + separator) { return true }
        return named(reference: reference, name: name) == existing
    }
}
