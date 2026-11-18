import Foundation

/// Display & HUD › Answers on the lens (Plan MG decision 5): how an answer is shown on the Meta
/// Display — one view the band scrolls (the default), or pages turned with **Next ›**. Even and the
/// web mirror always page. Pure.
enum LensAnswerStyle: String, CaseIterable, Identifiable, Sendable {
    case scroll
    case pages

    var id: String { rawValue }

    static let storageKey = "lensAnswerStyle"

    /// The stored choice; Scroll when nothing (or something unknown) is stored.
    static func stored(_ defaults: UserDefaults = .standard) -> LensAnswerStyle {
        defaults.string(forKey: storageKey).flatMap(LensAnswerStyle.init(rawValue:)) ?? .scroll
    }
}
