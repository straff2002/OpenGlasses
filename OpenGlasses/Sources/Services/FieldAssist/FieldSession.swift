import Foundation
import CoreLocation

/// A long-lived field-service session — represents one technician visit to one asset.
/// Sessions persist across app launches and emit a structured audit log on completion.
struct FieldSession: Codable, Identifiable, Equatable {
    let id: String
    let vaultId: String
    let assetId: String?
    let mode: Mode
    let startedAt: Date
    var endedAt: Date?
    var pausedAt: Date?
    var resumedAt: Date?
    var outcome: Outcome
    var startLocation: GeoPoint?
    var endLocation: GeoPoint?
    var escalations: [Escalation]
    var billableSeconds: TimeInterval
    /// Billing presentation captured when the job starts, so later settings changes do not rewrite
    /// an existing work record.
    var billingBasis: FieldAssistBillingBasis = .minutes
    var minutesPerBillingUnit: Int = 15
    /// The machine the session is working on, once it has been recognised (Plan EL). Optional and
    /// synthesized-key, so a session written before this existed decodes with it nil.
    var equipment: EquipmentIdentity?

    /// The job this visit belongs to, as the work order names it. Spoken at the start, or carried
    /// in by an organisation profile.
    var jobReference: String?
    /// The saved conversation this job owns (Plan FO P1). Everything said on the job lives in one
    /// thread, reviewable later under the job number, rather than one thread per wake-word turn.
    /// Nil until the job has a thread to bind — creation is lazy, see `JobThreadPolicy`.
    var conversationThreadId: String?
    /// True once the technician answered "start a separate chat" to the question raised when they
    /// tried to leave the job's thread. The id above is kept so the job can still be reviewed;
    /// turns simply stop resolving to it.
    var conversationThreadDetached: Bool = false
    /// Where the job number stands. Persisted, because "still owed" must survive a restart.
    var jobIntake: JobIntakeState = .needsReference
    /// A change-of-unit question that has been put and not yet answered. Persisted for the same
    /// reason: a question the app forgot it asked is worse than one it never asked.
    var pendingUnitChange: PendingUnitChange?
    /// Every unit this job has covered, in the order they were first seen. `equipment` holds only
    /// the current one; a job may legitimately span several.
    var visitedUnits: [VisitedUnit] = []
    /// What was recommended and what was decided about it, in the order it happened.
    var tasks: [Task] = []
    /// What base is being asked for. A request may stand without a task.
    var partsRequests: [PartsRequest] = []
    /// Model, serial, board part number, firmware, refrigerant — each with where it came from.
    var identityFields: [DeviceIdentityField] = []
    /// Readings, photos, opened citations and verified pages recorded while no task was active.
    var jobEvidence: Evidence = Evidence()
    /// A new scope on equipment change prevents carrying work onto another machine (FM).
    var continuityScope: String = "initial"
    var taskEquipmentScopes: [String: String] = [:]
    var identityEquipmentScopes: [String: String] = [:]
    var procedureEquipmentScope: String?

    func belongsToCurrentEquipment(_ task: Task) -> Bool {
        (taskEquipmentScopes[task.id] ?? "initial") == continuityScope
    }

    enum Mode: String, Codable {
        /// AI is the remote expert; grounded by vault content.
        case aiOnly = "ai_only"
        /// Human expert joins via WebRTC; AI assists with knowledge lookup + transcription.
        case humanAssisted = "human_assisted"

        var customerDescription: String {
            switch self {
            case .aiOnly: return "AI-assisted (no remote expert joined)"
            case .humanAssisted: return "AI-assisted with a remote expert"
            }
        }
    }

    enum Outcome: String, Codable {
        case inProgress = "in_progress"
        case paused
        case resolved
        case escalated
        case deferred
        case cancelled

        var displayName: String {
            switch self {
            case .inProgress: return "In progress"
            case .paused: return "Paused"
            case .resolved: return "Resolved"
            case .escalated: return "Escalated"
            case .deferred: return "Deferred"
            case .cancelled: return "Cancelled"
            }
        }
    }

    struct GeoPoint: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let recordedAt: Date

        init(latitude: Double, longitude: Double, recordedAt: Date = Date()) {
            self.latitude = latitude
            self.longitude = longitude
            self.recordedAt = recordedAt
        }

        init(_ location: CLLocation) {
            self.latitude = location.coordinate.latitude
            self.longitude = location.coordinate.longitude
            self.recordedAt = location.timestamp
        }
    }

    struct Escalation: Codable, Equatable {
        let timestamp: Date
        let reason: String
        var resolvedAt: Date?
    }

    /// Computed: whether the session is currently accepting input.
    var isActive: Bool {
        endedAt == nil && outcome == .inProgress
    }

    /// The task work is currently being recorded against, if any. The **most recent** one in
    /// progress: "add a task: cleaned the condensate trap" while something else is running means
    /// the technician has moved on to the trap, and the evidence should follow them.
    var activeTask: Task? { tasks.last { $0.status == .inProgress && belongsToCurrentEquipment($0) } }

    /// The most recent recommendation still awaiting a decision — what "do it" and "skip that"
    /// resolve to when the technician names no task.
    var latestRecommendation: Task? {
        tasks.last { $0.status == .recommended && belongsToCurrentEquipment($0) }
    }

    /// The task "start" picks up when the technician names none: something accepted or put off
    /// earlier, most recent first.
    var nextStartable: Task? {
        tasks.last { ($0.status == .accepted || $0.status == .deferred) && belongsToCurrentEquipment($0) }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, vaultId, assetId, mode, startedAt, endedAt, pausedAt, resumedAt, outcome
        case startLocation, endLocation, escalations, billableSeconds, billingBasis
        case minutesPerBillingUnit, equipment
        case jobReference, tasks, partsRequests, identityFields, jobEvidence
        case continuityScope, taskEquipmentScopes, identityEquipmentScopes, procedureEquipmentScope
        case conversationThreadId, conversationThreadDetached, jobIntake, pendingUnitChange
        case visitedUnits
    }
}

// MARK: - Codable

extension FieldSession {
    /// Hand-written so a session recorded before any of this existed still decodes.
    ///
    /// Swift's synthesized decoder throws on a missing key for a non-optional property — a default
    /// value on the property is not consulted — so every field added after a session was first
    /// written has to be decoded as "if present". Optional fields would have decoded either way;
    /// the collections would not.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vaultId = try c.decode(String.self, forKey: .vaultId)
        assetId = try c.decodeIfPresent(String.self, forKey: .assetId)
        mode = try c.decode(Mode.self, forKey: .mode)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        pausedAt = try c.decodeIfPresent(Date.self, forKey: .pausedAt)
        resumedAt = try c.decodeIfPresent(Date.self, forKey: .resumedAt)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        startLocation = try c.decodeIfPresent(GeoPoint.self, forKey: .startLocation)
        endLocation = try c.decodeIfPresent(GeoPoint.self, forKey: .endLocation)
        escalations = try c.decodeIfPresent([Escalation].self, forKey: .escalations) ?? []
        billableSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .billableSeconds) ?? 0
        billingBasis = try c.decodeIfPresent(FieldAssistBillingBasis.self, forKey: .billingBasis) ?? .minutes
        minutesPerBillingUnit = max(1, try c.decodeIfPresent(Int.self, forKey: .minutesPerBillingUnit) ?? 15)
        equipment = try c.decodeIfPresent(EquipmentIdentity.self, forKey: .equipment)
        jobReference = try c.decodeIfPresent(String.self, forKey: .jobReference)
        tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) ?? []
        partsRequests = try c.decodeIfPresent([PartsRequest].self, forKey: .partsRequests) ?? []
        identityFields = try c.decodeIfPresent([DeviceIdentityField].self, forKey: .identityFields) ?? []
        jobEvidence = try c.decodeIfPresent(Evidence.self, forKey: .jobEvidence) ?? Evidence()
        continuityScope = try c.decodeIfPresent(String.self, forKey: .continuityScope) ?? "initial"
        taskEquipmentScopes = try c.decodeIfPresent([String: String].self, forKey: .taskEquipmentScopes) ?? [:]
        identityEquipmentScopes = try c.decodeIfPresent([String: String].self, forKey: .identityEquipmentScopes) ?? [:]
        procedureEquipmentScope = try c.decodeIfPresent(String.self, forKey: .procedureEquipmentScope)
        conversationThreadId = try c.decodeIfPresent(String.self, forKey: .conversationThreadId)
        conversationThreadDetached = try c.decodeIfPresent(Bool.self, forKey: .conversationThreadDetached) ?? false
        // A session written before the guided flow existed has no intake state. Its number is
        // either already recorded or it was never asked for — and asking for it now, days later,
        // would be nonsense, so a legacy session with no number is `.notRequired` rather than
        // outstanding.
        if let intake = try c.decodeIfPresent(JobIntakeState.self, forKey: .jobIntake) {
            jobIntake = intake
        } else if let reference = jobReference {
            jobIntake = .recorded(reference: reference)
        } else {
            jobIntake = .notRequired
        }
        pendingUnitChange = try c.decodeIfPresent(PendingUnitChange.self, forKey: .pendingUnitChange)
        visitedUnits = try c.decodeIfPresent([VisitedUnit].self, forKey: .visitedUnits) ?? []
    }
}

enum FieldAssistBillingBasis: String, Codable, CaseIterable {
    case minutes
    case units

    var label: String { self == .minutes ? "Minutes" : "Units" }

    static func units(for seconds: TimeInterval, minutesPerUnit: Int) -> Int {
        guard seconds > 0 else { return 0 }
        let unitSeconds = Double(max(1, minutesPerUnit) * 60)
        return max(1, Int(ceil(seconds / unitSeconds)))
    }
}
