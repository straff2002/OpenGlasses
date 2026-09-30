import CoreLocation
import Foundation

/// Plan GH — "where did I park?" in words: the level and space, how far and which way, how long
/// ago, and — when the saved position was already old — how old. One spoken sentence and one
/// terse HUD line ("Car · L2 · 41 · 300 m NE"), both pure.
enum ParkingRecallPhraser {

    /// A saved fix this much older than the save is called out in the recall.
    static let staleFixThreshold: TimeInterval = 5 * 60
    /// Closer than this, distance and direction are noise; "right around here" instead.
    static let hereRadius: Double = 15

    // MARK: - Spoken

    static func spoken(_ spot: ParkingSpot, from current: CLLocationCoordinate2D?, now: Date,
                       metric: Bool) -> String {
        var sentences: [String] = []
        let details = detailPhrase(spot)
        let ago = agePhrase(now.timeIntervalSince(spot.savedAt))

        switch spot.confidence {
        case .certain:
            sentences.append(details.map { "You parked \($0)" } ?? "I have your parking spot")
        case .probable:
            let base = details.map { "I think you parked \($0)" } ?? "I think I know where you parked"
            sentences.append(base)
        }

        if let target = spot.coordinate {
            if let current {
                let meters = distance(from: current, to: target)
                if meters <= hereRadius {
                    sentences.append("It's right around here")
                } else {
                    let banded = DistanceFormatter.banded(meters)
                    let direction = compassPoint(bearing(from: current, to: target)).spoken
                    sentences.append("It's about \(DistanceFormatter.spoken(banded, metric: metric)) \(direction)")
                }
            } else {
                sentences.append("I can't tell how far it is until I have your location")
            }
        } else {
            sentences.append("I don't have a map position for it, only what you told me")
        }

        switch spot.capture {
        case .motion:
            sentences.append("I saved it automatically when your drive ended \(ago)")
        case .carPlayDisconnect:
            sentences.append("I saved it when CarPlay disconnected \(ago)")
        case .voice, .photo:
            sentences.append("Saved \(ago)")
        }

        if let lag = spot.locationLag, lag >= staleFixThreshold {
            sentences.append("That position is from \(durationPhrase(lag)) before it was saved, so it may be off")
        }
        if let note = spot.note, !note.isEmpty {
            sentences.append("Your note: \(note)")
        }

        var text = sentences.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
        if let target = spot.coordinate, let current, distance(from: current, to: target) > hereRadius {
            text += " Want directions?"
        }
        return text
    }

    /// "on level 2, space 41, in the green zone" — nil when nothing but a position was saved.
    static func detailPhrase(_ spot: ParkingSpot) -> String? {
        var parts: [String] = []
        if let level = spot.level, !level.isEmpty { parts.append(levelPhrase(level)) }
        if let space = spot.space, !space.isEmpty { parts.append("space \(space)") }
        if let zone = spot.zone, !zone.isEmpty {
            parts.append(zone.hasPrefix("Row ") || zone.hasPrefix("Zone ") ? "in \(zone.lowercasedFirstWord)"
                                                                           : "in the \(zone.lowercased()) zone")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    static func levelPhrase(_ level: String) -> String {
        switch level {
        case "G": return "on the ground floor"
        case "Roof": return "on the roof"
        default:
            if let n = Int(level), n < 0 { return "on level minus \(-n)" }
            if level.first?.isLetter == true, level.count > 1, level.dropFirst().allSatisfy(\.isLetter) {
                return "on the \(level.lowercased()) level"   // "Blue" → "on the blue level"
            }
            return "on level \(level)"
        }
    }

    // MARK: - HUD

    /// "Car · L2 · 41 · 300 m NE". Omits what it doesn't have.
    static func hudLine(_ spot: ParkingSpot, from current: CLLocationCoordinate2D?, metric: Bool) -> String {
        var parts = ["Car"]
        if let level = spot.level, !level.isEmpty {
            parts.append(level.first?.isNumber == true || level.hasPrefix("-") ? "L\(level)" : level)
        }
        if let space = spot.space, !space.isEmpty { parts.append(space) }
        if spot.level == nil, spot.space == nil, let zone = spot.zone { parts.append(zone) }
        if let target = spot.coordinate, let current {
            let meters = distance(from: current, to: target)
            if meters <= hereRadius {
                parts.append("here")
            } else {
                let banded = DistanceFormatter.banded(meters)
                parts.append("\(DistanceFormatter.compact(banded, metric: metric)) \(compassPoint(bearing(from: current, to: target)).short)")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Time

    /// "just now", "5 minutes ago", "2 hours ago", "yesterday", "3 days ago".
    static func agePhrase(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 90 { return "just now" }
        return durationPhrase(seconds) + " ago"
    }

    /// "5 minutes", "an hour", "2 hours", "a day", "3 days".
    static func durationPhrase(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded())
        if minutes < 60 { return minutes <= 1 ? "a minute" : "\(minutes) minutes" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return hours == 1 ? "an hour" : "\(hours) hours" }
        let days = Int((Double(hours) / 24).rounded())
        return days == 1 ? "a day" : "\(days) days"
    }

    // MARK: - Geometry

    static func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Initial great-circle bearing in degrees, 0 = north, clockwise.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compassPoint(_ bearing: Double) -> (spoken: String, short: String) {
        let points: [(String, String)] = [
            ("north", "N"), ("north-east", "NE"), ("east", "E"), ("south-east", "SE"),
            ("south", "S"), ("south-west", "SW"), ("west", "W"), ("north-west", "NW"),
        ]
        let normalised = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((normalised / 45).rounded()) % 8
        return points[index]
    }
}

private extension String {
    /// "Row G" → "row G"; "Zone C" → "zone C".
    var lowercasedFirstWord: String {
        guard let space = firstIndex(of: " ") else { return lowercased() }
        return self[..<space].lowercased() + self[space...]
    }
}
