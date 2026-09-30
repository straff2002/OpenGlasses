import CoreLocation
import Foundation

/// Plan GH — one remembered parking spot.
///
/// The coordinate is optional on purpose: a spot said aloud three levels underground, where there
/// is no fix at all, is still worth keeping for its level and space — indoors those carry the
/// answer and the pin does not. `locationAt` is separate from `savedAt` because an automatic save
/// can only use the last fix the phone had, and the recall owes the wearer how old that fix was.
struct ParkingSpot: Codable, Equatable, Identifiable {

    /// How the spot was captured.
    enum Capture: String, Codable, CaseIterable {
        /// Said aloud ("I parked on level 2, space 41").
        case voice
        /// Read from a sign through the camera.
        case photo
        /// Saved when CarPlay disconnected after a drive.
        case carPlayDisconnect
        /// Saved when motion went from driving to walking ("I drive" on).
        case motion

        /// The wearer told us, as opposed to the phone inferring it.
        var isManual: Bool { self == .voice || self == .photo }
    }

    /// How sure the app is that this is where the car is.
    enum Confidence: String, Codable {
        /// The wearer said so, or CarPlay disconnected with a fresh fix.
        case certain
        /// Inferred from motion, or from a fix that was already old — a passenger produces the
        /// same pattern as a driver, and the recall says so.
        case probable
    }

    var id: UUID
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    /// When the coordinate was fixed. Earlier than `savedAt` when the save used a last-known fix.
    var locationAt: Date?
    var level: String?
    var space: String?
    var zone: String?
    var note: String?
    /// File name of the sign photo inside the store's photo folder, never a path.
    var photoFile: String?
    var savedAt: Date
    var capture: Capture
    var confidence: Confidence

    init(id: UUID = UUID(),
         coordinate: CLLocationCoordinate2D? = nil,
         horizontalAccuracy: Double? = nil,
         locationAt: Date? = nil,
         level: String? = nil, space: String? = nil, zone: String? = nil, note: String? = nil,
         photoFile: String? = nil,
         savedAt: Date,
         capture: Capture,
         confidence: Confidence? = nil) {
        self.id = id
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.locationAt = locationAt
        self.level = level
        self.space = space
        self.zone = zone
        self.note = note
        self.photoFile = photoFile
        self.savedAt = savedAt
        self.capture = capture
        self.confidence = confidence ?? (capture == .motion ? .probable : .certain)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isManual: Bool { capture.isManual }

    /// How much older the fix is than the save. Nil when there is no fix or no fix time.
    var locationLag: TimeInterval? {
        guard let locationAt, coordinate != nil else { return nil }
        return max(0, savedAt.timeIntervalSince(locationAt))
    }

    /// Whether any level/space/zone/note detail was captured.
    var hasDetails: Bool {
        [level, space, zone, note].contains { !($0 ?? "").isEmpty }
    }

    /// Copy the parsed fields in, leaving existing ones where the new reading has nothing.
    mutating func merge(_ fields: ParkingFields) {
        if let value = fields.level { level = value }
        if let value = fields.space { space = value }
        if let value = fields.zone { zone = value }
        if let value = fields.note { note = value }
    }
}

/// The level/space/zone/note triple both parsers produce.
struct ParkingFields: Equatable {
    var level: String?
    var space: String?
    var zone: String?
    var note: String?

    init(level: String? = nil, space: String? = nil, zone: String? = nil, note: String? = nil) {
        self.level = level
        self.space = space
        self.zone = zone
        self.note = note
    }

    var isEmpty: Bool { level == nil && space == nil && zone == nil && note == nil }
}

/// Plan GH — which spot wins when a new one arrives.
///
/// The rule from the plan, widened slightly: an *automatic* spot never replaces one the wearer
/// saved themselves in the last ten minutes. The plan named only `probable` spots, but a CarPlay
/// disconnect a minute after "I parked on level 2, space 41" would otherwise erase the level and
/// space the wearer just gave for a bare coordinate of the same place. The reverse direction
/// merges: a spoken spot with no fix (underground) keeps the coordinate of an automatic spot saved
/// in the same window, because that is the same car.
enum ParkingReplacementPolicy {
    static let manualProtectionWindow: TimeInterval = 10 * 60

    enum Resolution: Equatable {
        /// Store this spot as the active one.
        case replace(ParkingSpot)
        /// Keep the existing spot; the candidate is dropped.
        case keepExisting
    }

    static func resolve(existing: ParkingSpot?, candidate: ParkingSpot, now: Date) -> Resolution {
        guard let existing else { return .replace(candidate) }
        let recent = now.timeIntervalSince(existing.savedAt) < manualProtectionWindow

        if !candidate.isManual, existing.isManual, recent {
            return .keepExisting
        }
        if candidate.isManual, candidate.coordinate == nil, !existing.isManual, recent,
           existing.coordinate != nil {
            var merged = candidate
            merged.latitude = existing.latitude
            merged.longitude = existing.longitude
            merged.horizontalAccuracy = existing.horizontalAccuracy
            merged.locationAt = existing.locationAt
            return .replace(merged)
        }
        return .replace(candidate)
    }
}
