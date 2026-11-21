import Foundation

/// Display & HUD › Keep answers up (Plan MU §4, decision 2): how long the reading view stays on the
/// Meta Display without a press. **Until closed** (the default) keeps it until **Close**, a new
/// answer, the end of a private conversation, the HUD turning off or a long disconnect; the lens
/// still dims and sleeps on Meta's own timer. **3 minutes** is MG's lifetime. The paged card (Pages,
/// and Even's lens) keeps its own 60 s whichever is chosen. Pure.
enum LensAnswerLifetime: String, CaseIterable, Identifiable, Sendable {
    case untilClosed
    case threeMinutes

    var id: String { rawValue }

    static let storageKey = "lensAnswerLifetime"

    /// The reading view's idle lifetime: none until closed.
    var idleLifetime: TimeInterval? {
        switch self {
        case .untilClosed: return nil
        case .threeMinutes: return 3 * 60
        }
    }

    /// The stored choice; Until closed when nothing (or something unknown) is stored.
    static func stored(_ defaults: UserDefaults = .standard) -> LensAnswerLifetime {
        defaults.string(forKey: storageKey).flatMap(LensAnswerLifetime.init(rawValue:)) ?? .untilClosed
    }
}
