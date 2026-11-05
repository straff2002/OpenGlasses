import Foundation

/// Plan GM P1a — **Go** on a wrist map card: the watch sends `startGuidance` with the card's id
/// (and, from a nearby list, the row's id); the phone looks the card up on `GlanceSurfaceBus` and
/// starts walking guidance to it. The command carries no travel mode: the phone decides (walking
/// until Plan GL's resolver lands). Pure resolution and reply wording, so every reply is a test.
enum WatchStartGuidance {

    static let command = GlanceWire.startGuidanceCommand
    static let surfaceIdKey = GlanceWire.surfaceIdKey
    static let placeIdKey = GlanceWire.placeIdKey

    /// Where to walk to.
    struct Target: Equatable {
        let coordinate: GlancePoint
        let label: String
    }

    enum Resolution: Equatable {
        case start(Target)
        case refuse(String)
    }

    /// What the wrist is told.
    enum Reply: Equatable {
        /// Guidance began; the phone's spoken confirmation.
        case started(String)
        /// It did not, and why.
        case refused(String)
        /// The phone cannot begin location updates from the background: the wearer has to open it.
        case openPhone
    }

    static let goneMessage = "That card has gone. Ask again to see it here."
    static let nowhereMessage = "There's nowhere to go on that card."
    static let openPhoneMessage = "Open Avenkin on your iPhone to start."

    /// The target for a `startGuidance` message, given the live card (nil when there is none).
    static func resolve(surfaceId: String?, placeId: String?, live surface: GlanceSurface?) -> Resolution {
        guard let surfaceId, let surface, surface.id == surfaceId else { return .refuse(goneMessage) }
        switch surface.kind {
        case .place(let card):
            return .start(Target(coordinate: card.coordinate, label: card.name))
        case .places(let card):
            guard let placeId, let row = card.rows.first(where: { $0.id == placeId }) else {
                return .refuse(goneMessage)
            }
            return .start(Target(coordinate: row.coordinate, label: row.name))
        case .whereAmI, .route, .list, .image:
            return .refuse(nowhereMessage)
        }
    }

    /// The reply for how the start went. A missing fix while the phone is in the background is
    /// the "open the phone" case: when-in-use location cannot start from a background launch.
    static func reply(spoken: String?, error: Error?, appIsActive: Bool) -> Reply {
        if let error {
            if (error as? NavigationError) == .noLocation, !appIsActive { return .openPhone }
            return .refused(error.localizedDescription)
        }
        return .started(spoken ?? "Starting walking directions.")
    }

    /// The reply as the watch's `sendCommand` reads it: `response` for success, `error` otherwise.
    static func dictionary(_ reply: Reply) -> [String: Any] {
        switch reply {
        case .started(let text): return ["status": "started", "response": text]
        case .refused(let reason): return ["status": "refused", "error": reason]
        case .openPhone: return ["status": "openPhone", "error": openPhoneMessage]
        }
    }
}
