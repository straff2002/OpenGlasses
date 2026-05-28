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

    enum Mode: String, Codable {
        /// AI is the remote expert; grounded by vault content.
        case aiOnly = "ai_only"
        /// Human expert joins via WebRTC; AI assists with knowledge lookup + transcription.
        case humanAssisted = "human_assisted"
    }

    enum Outcome: String, Codable {
        case inProgress = "in_progress"
        case paused
        case resolved
        case escalated
        case deferred
        case cancelled
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
}
