import Combine
import Foundation

/// Plan GM P1a — where spatial tools hand their structured answer. Tools never talk to
/// WatchConnectivity: each returns its sentence as before **and** publishes a `GlanceSurface`
/// here; the watch publisher subscribes today, and the phone's conversation map (Plan HH) will
/// subscribe to the same values. Owned by `AppState`.
@MainActor
final class GlanceSurfaceBus: ObservableObject {

    /// One surface, and whether the wearer asked to see it ("show me on my watch").
    struct Publication: Equatable {
        let surface: GlanceSurface
        let asked: Bool
    }

    /// The latest card, expired or not; read `current` for one still worth showing.
    @Published private(set) var latest: Publication?

    var now: () -> Date = Date.init

    func publish(_ surface: GlanceSurface, asked: Bool = false) {
        latest = Publication(surface: surface, asked: asked)
    }

    /// The latest card while it is live.
    var current: GlanceSurface? {
        guard let surface = latest?.surface, !surface.isExpired(at: now()) else { return nil }
        return surface
    }

    /// The live card with `id` — what a tap on the wrist refers back to.
    func surface(id: String) -> GlanceSurface? {
        guard let current, current.id == id else { return nil }
        return current
    }

    func clear() {
        latest = nil
    }
}
