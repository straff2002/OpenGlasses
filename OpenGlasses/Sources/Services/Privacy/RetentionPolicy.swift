import Foundation

/// W03.3 — what expires, when, and on whose say-so.
///
/// The finding this answers is that retention existed for exactly two directories, ran only while
/// compliance mode was on, and left every other store to grow forever. The fix is not "purge more":
/// it is to make a period an explicit, attributable decision per data class, including where that
/// decision is *not to expire anything*. A policy that is off says why it is off, because "nothing
/// happens here" and "nobody has decided yet" are different states and only one of them is a
/// finding.
struct RetentionPolicy: Equatable {

    enum Trigger: Equatable {
        /// Nothing expires. The reason is part of the policy rather than an omission.
        case off(String)
        /// Records older than this go.
        case maxAge(TimeInterval)
        /// A fixed cap the owner already applies on write, so a sweep has nothing to do. Recorded
        /// so the register covers the class rather than leaving a hole where the answer is "the
        /// store handles it".
        case capEnforcedOnWrite(Int)
    }

    let dataClass: SensitiveStore.DataClass
    let trigger: Trigger
    /// Where the number comes from, in words a reader can check against the app.
    let source: String

    /// The instant before which a record has expired, or nil when nothing expires.
    func cutoff(from now: Date) -> Date? {
        guard case .maxAge(let age) = trigger else { return nil }
        return now.addingTimeInterval(-age)
    }

    var isActive: Bool { cutoff(from: Date()) != nil }

    var rendered: String {
        switch trigger {
        case .off(let reason): return "off — \(reason)"
        case .maxAge(let age): return "\(Int(age / 86_400)) day(s) — \(source)"
        case .capEnforcedOnWrite(let cap): return "cap \(cap) on write — \(source)"
        }
    }
}

/// The periods that are not a wearer setting, in one place so the numbers can be argued with.
enum RetentionDefaults {
    /// Migration and salvage leftovers: a retired copy of a store, kept only so a bad migration
    /// can be investigated. Long enough for somebody to notice and ask for help, short enough that
    /// a second copy of the wearer's memories is not kept indefinitely beside the first.
    static let leftoverMaxAge: TimeInterval = 14 * 24 * 3600

    /// Staging directories for an install that was approved and then abandoned. Well past the
    /// five-minute consent lifetime, so a sweep can never take a session that is still live.
    static let stagingMaxAge: TimeInterval = 3600

    /// How often the scheduler is willing to do the work. The check that reads this is a date
    /// comparison, so a launch and a foreground cost nothing when nothing is due.
    static let interval: TimeInterval = 6 * 3600
}

/// The wearer- and operator-set periods the policies read. A value type so a test can pose a
/// setting without touching preferences.
struct RetentionSettings: Equatable {
    /// Clinical retention in days; 0 means keep everything. Set on the clinical settings screen.
    var clinicalDays: Int
    /// The wearer's own history — conversations and personal memory. 0 (the default) means keep
    /// everything, and that default is deliberate: deleting somebody's own record of their life
    /// because they never opened a settings screen is a worse failure than keeping it.
    var wearerHistoryDays: Int

    static var current: RetentionSettings {
        RetentionSettings(clinicalDays: Config.hipaaRetentionDays,
                          wearerHistoryDays: Config.historyRetentionDays)
    }
}

/// The register: one policy per data class, derived from the settings rather than hard-coded.
enum RetentionPolicyBook {

    static func policy(for dataClass: SensitiveStore.DataClass,
                       settings: RetentionSettings) -> RetentionPolicy {
        switch dataClass {

        case .clinical:
            // Honoured whether or not compliance mode is on. A clinic that turned the mode off
            // after recording did not thereby ask for the transcripts to be kept forever, and the
            // old behaviour — retention only while the mode was enabled — meant exactly that.
            guard settings.clinicalDays > 0 else {
                return RetentionPolicy(dataClass: dataClass, trigger: .off(
                    "the clinical retention period is set to zero, which means keep everything"),
                    source: "clinical settings")
            }
            return RetentionPolicy(dataClass: dataClass,
                                   trigger: .maxAge(TimeInterval(settings.clinicalDays) * 86_400),
                                   source: "clinical settings")

        case .conversationContent, .personalMemory:
            guard settings.wearerHistoryDays > 0 else {
                return RetentionPolicy(dataClass: dataClass, trigger: .off(
                    "the wearer has not asked for their own history to expire"),
                    source: "history retention setting, off by default")
            }
            return RetentionPolicy(dataClass: dataClass,
                                   trigger: .maxAge(TimeInterval(settings.wearerHistoryDays) * 86_400),
                                   source: "history retention setting")

        case .derivedIndex:
            // The salvage and migration copies: derived from a store, kept only for recovery.
            return RetentionPolicy(dataClass: dataClass,
                                   trigger: .maxAge(RetentionDefaults.leftoverMaxAge),
                                   source: "fixed: recovery copies outlive their usefulness quickly")

        case .exportArtifact:
            return RetentionPolicy(dataClass: dataClass,
                                   trigger: .maxAge(RetentionDefaults.stagingMaxAge),
                                   source: "fixed: an export is a lease, released on share or swept")

        case .operationalAudit:
            return RetentionPolicy(dataClass: dataClass, trigger: .capEnforcedOnWrite(1000),
                                   source: "the audit log and the operation journal evict on append")

        case .biometric:
            return RetentionPolicy(dataClass: dataClass, trigger: .off(
                "a face is enrolled deliberately and forgotten deliberately; expiring one silently "
                    + "would un-recognise somebody the wearer asked to be reminded of"),
                source: "product decision")

        case .knowledgeGraph:
            return RetentionPolicy(dataClass: dataClass, trigger: .off(
                "the graph ages facts by confidence rather than by deleting them; see the distiller"),
                source: "store behaviour")

        case .media:
            return RetentionPolicy(dataClass: dataClass, trigger: .off(
                "recordings and photos are the wearer's own media, removed per file"),
                source: "product decision")

        case .documentCorpus, .skillDefinition, .socialProfile, .locationData, .preference, .credential:
            return RetentionPolicy(dataClass: dataClass, trigger: .off(
                "content the wearer added on purpose; it goes when they remove it or erase a subject"),
                source: "product decision")
        }
    }

    /// The whole register, for the settings screen and the plan.
    static func all(settings: RetentionSettings) -> [RetentionPolicy] {
        let classes: [SensitiveStore.DataClass] = [
            .conversationContent, .derivedIndex, .personalMemory, .knowledgeGraph, .documentCorpus,
            .biometric, .socialProfile, .media, .clinical, .operationalAudit, .credential,
            .preference, .exportArtifact, .locationData, .skillDefinition,
        ]
        return classes.map { policy(for: $0, settings: settings) }
    }
}

/// One thing a sweep can remove, seen only by its age. The identifier is opaque and never logged:
/// a transcript's filename is frequently a date and a patient.
struct RetentionCandidate: Equatable {
    let id: String
    let created: Date
}

/// The pure half of a purge: given candidates and a policy, which ones have expired.
enum RetentionPlan {

    /// Strictly older than the cutoff expires.
    ///
    /// A record made exactly at the cutoff is *inside* the period and stays — a retention period of
    /// N days means N days are kept, not N days minus an instant. The boundary is asserted in both
    /// directions by `RetentionSchedulerTests`, because an off-by-one here deletes a day of
    /// somebody's records early and nothing else in the system would notice.
    static func expired(_ candidates: [RetentionCandidate],
                        policy: RetentionPolicy,
                        now: Date) -> [RetentionCandidate] {
        guard let cutoff = policy.cutoff(from: now) else { return [] }
        return candidates.filter { $0.created < cutoff }
    }
}
