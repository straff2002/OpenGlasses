import Foundation

/// Plan CA — distance display/speech formatting, metric or imperial, HUD-compact or spoken.
enum DistanceFormatter {

    /// Banded distance so the HUD line doesn't churn on every GPS tick: 0 means "now"
    /// (≤15 m), then nearest 10 under 100 m, nearest 50 under 1 km, nearest 100 beyond.
    static func banded(_ meters: Double) -> Int {
        guard meters > 15 else { return 0 }
        if meters < 100 { return Int((meters / 10).rounded()) * 10 }
        if meters < 1000 { return Int((meters / 50).rounded()) * 50 }
        return Int((meters / 100).rounded()) * 100
    }

    /// "40 m" / "1.2 km" — or "130 ft" / "0.8 mi".
    static func compact(_ meters: Int, metric: Bool) -> String {
        if metric {
            if meters < 1000 { return "\(meters) m" }
            return String(format: "%.1f km", Double(meters) / 1000)
        }
        let feet = Double(meters) * 3.28084
        if feet < 1000 { return "\(Int((feet / 10).rounded()) * 10) ft" }
        return String(format: "%.1f mi", Double(meters) / 1609.344)
    }

    /// "40 metres" / "1.2 kilometres" — or "130 feet" / "0.8 miles".
    static func spoken(_ meters: Int, metric: Bool) -> String {
        if metric {
            if meters < 1000 { return "\(meters) metres" }
            let km = Double(meters) / 1000
            return km == km.rounded() ? "\(Int(km)) kilometres" : String(format: "%.1f kilometres", km)
        }
        let feet = Double(meters) * 3.28084
        if feet < 1000 { return "\(Int((feet / 10).rounded()) * 10) feet" }
        return String(format: "%.1f miles", Double(meters) / 1609.344)
    }
}

/// Plan CA — one maneuver, two renderings: the terse HUD card and the spoken cue.
enum ManeuverPhraser {

    /// "← 40 m · King St" / "← King St" (imminent) / "⚑ 200 m" (no street).
    static func hudLine(maneuver: Maneuver, streetName: String?, bandedMeters: Int, metric: Bool) -> String {
        var parts: [String] = [maneuver.arrow]
        if bandedMeters > 0 {
            parts.append(DistanceFormatter.compact(bandedMeters, metric: metric))
        }
        if let street = streetName, !street.isEmpty {
            parts.append(bandedMeters > 0 ? "· \(street)" : street)
        }
        if parts.count == 1 {
            parts.append(bandedMeters == 0 ? "now" : "")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "In 40 metres, turn left onto King Street." / "Turn left onto King Street now."
    /// Arrival: "In 40 metres, you'll arrive at your destination." / "You've arrived."
    static func spoken(maneuver: Maneuver, streetName: String?, bandedMeters: Int, metric: Bool) -> String {
        if maneuver == .arrive {
            if bandedMeters == 0 { return "You've arrived." }
            return "In \(DistanceFormatter.spoken(bandedMeters, metric: metric)), you'll arrive at your destination."
        }
        var phrase = maneuver.verb
        if let street = streetName, !street.isEmpty {
            let connector = (maneuver == .continueStraight || maneuver == .depart) ? "on" : "onto"
            phrase += " \(connector) \(street)"
        }
        if bandedMeters == 0 {
            return phrase.prefix(1).uppercased() + phrase.dropFirst() + " now."
        }
        return "In \(DistanceFormatter.spoken(bandedMeters, metric: metric)), \(phrase)."
    }
}

/// When to actually speak (pure): once as a step becomes active (the approach cue) and once
/// when its banded distance reaches "now" (the imminent cue) — never on every band change.
struct NavigationCuePolicy {
    enum Cue: Equatable { case approach, imminent }

    private var announcedApproachFor = -1
    private var announcedImminentFor = -1

    mutating func cue(stepIndex: Int, bandedMeters: Int) -> Cue? {
        if stepIndex != announcedApproachFor {
            announcedApproachFor = stepIndex
            // A step that activates already imminent gets the imminent cue only, once.
            if bandedMeters == 0 { announcedImminentFor = stepIndex; return .imminent }
            return .approach
        }
        if bandedMeters == 0, stepIndex != announcedImminentFor {
            announcedImminentFor = stepIndex
            return .imminent
        }
        return nil
    }
}
