import Foundation
import UIKit

/// The maps apps directions can be handed to (Plan FO §7, P3c).
enum MapsApp: String, CaseIterable, Codable, Equatable {
    case apple
    case google
    case waze

    var label: String {
        switch self {
        case .apple: return "Apple Maps"
        case .google: return "Google Maps"
        case .waze: return "Waze"
        }
    }

    /// The URL `canOpenURL` is asked about. Nil for Apple Maps, which is always there. Each
    /// scheme has to be listed in `LSApplicationQueriesSchemes` — within the first fifty, the
    /// only ones iOS honours.
    var probeURL: URL? {
        switch self {
        case .apple: return nil
        case .google: return URL(string: "comgooglemaps://")
        case .waze: return URL(string: "waze://")
        }
    }

    /// What the tool's `app` argument and a spoken request may call it.
    init?(spoken: String) {
        let lowered = spoken.lowercased()
        if lowered.contains("waze") { self = .waze }
        else if lowered.contains("google") { self = .google }
        else if lowered.contains("apple") { self = .apple }
        else { return nil }
    }
}

enum TravelMode: String, Equatable {
    case driving
    case walking
    case transit

    init(spoken: String?) {
        switch spoken?.lowercased() {
        case "walking", "walk": self = .walking
        case "transit", "public transport": self = .transit
        default: self = .driving
        }
    }
}

/// Which app directions go to, and the URL that takes them there. Pure: whether an app is
/// installed is handed in, so every row of the preference table — including the missing-app
/// fallback — is a test.
struct MapsHandoff: Equatable {
    let app: MapsApp
    let url: URL
    let mode: TravelMode
    let destination: String
    /// The app that was asked for and could not be used, when there was one — said out loud, so
    /// a technician who chose Waze is never quietly given something else.
    let unavailable: MapsApp?
    let reason: Reason?

    enum Reason: Equatable {
        case notInstalled
        /// Waze gives driving directions only.
        case drivingOnly
    }

    /// - Parameters:
    ///   - preferred: the app asked for — the tool's argument, else the setting.
    ///   - isInstalled: whether an app can be opened. Apple Maps always can.
    static func plan(destination: String, mode: TravelMode = .driving, preferred: MapsApp,
                     isInstalled: (MapsApp) -> Bool) -> MapsHandoff? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var chosen = preferred
        var reason: Reason?
        if preferred == .waze, mode != .driving {
            chosen = .apple
            reason = .drivingOnly
        } else if preferred != .apple, !isInstalled(preferred) {
            chosen = .apple
            reason = .notInstalled
        }
        guard let url = url(for: chosen, destination: trimmed, mode: mode) else { return nil }
        return MapsHandoff(app: chosen, url: url, mode: mode, destination: trimmed,
                           unavailable: chosen == preferred ? nil : preferred, reason: reason)
    }

    static func url(for app: MapsApp, destination: String, mode: TravelMode) -> URL? {
        guard let encoded = encode(destination) else { return nil }
        switch app {
        case .apple:
            let flag: String
            switch mode {
            case .driving: flag = "d"
            case .walking: flag = "w"
            case .transit: flag = "r"
            }
            return URL(string: "maps://?daddr=\(encoded)&dirflg=\(flag)")
        case .google:
            return URL(string: "comgooglemaps://?daddr=\(encoded)&directionsmode=\(mode.rawValue)")
        case .waze:
            return URL(string: "waze://?q=\(encoded)&navigate=yes")
        }
    }

    /// Query-safe: `&`, `=`, `+`, `?` and `#` in an address are encoded, so "Smith & Sons, Unit
    /// 4#2" cannot split into a second parameter.
    static func encode(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// What the app says as it hands over.
    var spoken: String {
        let opening = "Opening \(mode.rawValue) directions to \(destination) in \(app.label)."
        guard let unavailable, let reason else { return opening }
        switch reason {
        case .notInstalled:
            return "\(unavailable.label) isn't installed, so I'm using Apple Maps instead. " + opening
        case .drivingOnly:
            return "\(unavailable.label) only does driving directions, so I'm using Apple Maps instead. " + opening
        }
    }
}

/// Opens a hand-off — on the car screen when a car is connected, so the maps app takes CarPlay,
/// otherwise on the phone.
@MainActor
enum MapsLauncher {
    static func isInstalled(_ app: MapsApp) -> Bool {
        guard let probe = app.probeURL else { return true }
        return UIApplication.shared.canOpenURL(probe)
    }

    static func plan(destination: String, mode: TravelMode = .driving,
                     requested: MapsApp? = nil) -> MapsHandoff? {
        MapsHandoff.plan(destination: destination, mode: mode,
                         preferred: requested ?? Config.preferredMapsApp,
                         isInstalled: { app in isInstalled(app) })
    }

    static func open(_ handoff: MapsHandoff) {
        if let car = CarPlaySceneDelegate.current, car.openOnCarScreen(handoff.url) { return }
        UIApplication.shared.open(handoff.url, options: [:], completionHandler: nil)
    }
}
