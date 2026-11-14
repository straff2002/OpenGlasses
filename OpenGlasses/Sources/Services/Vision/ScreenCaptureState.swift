import Combine
import UIKit

/// Whether the app's screen is being captured right now (Plan LT §1): a screen recording, a share
/// from Control Centre or an app such as FaceTime, or an AirPlay or cable mirror.
///
/// Read from the foreground window scene's `sceneCaptureState` trait, and watched for changes to
/// it. A scene without a definite reading falls back to its screen's capture flag, which iOS still
/// posts `capturedDidChangeNotification` for. One instance for the app: the preview surfaces read
/// it through `PreviewCapturePolicy`.
@MainActor
final class ScreenCaptureState: ObservableObject {

    static let shared = ScreenCaptureState()

    @Published private(set) var isCaptured = false

    private var observers: [NSObjectProtocol] = []
    private var traitRegistration: (any UITraitChangeRegistration)?
    private weak var observedWindow: UIWindow?

    private init() {
        let center = NotificationCenter.default
        for name in [UIScreen.capturedDidChangeNotification,
                     UIScene.didActivateNotification,
                     UIScene.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    /// Re-read the foreground scene, and watch the capture trait on its window if that is new.
    /// The window inherits the scene's traits, so its change handler fires when capture starts or
    /// stops.
    func refresh() {
        let scene = Self.foregroundScene()
        let window = scene?.keyWindow ?? scene?.windows.first
        if window !== observedWindow {
            observedWindow = window
            traitRegistration = window?.registerForTraitChanges([UITraitSceneCaptureState.self]) {
                [weak self] (_: UIWindow, _: UITraitCollection) in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let captured = Self.isCaptured(scene)
        if captured != isCaptured { isCaptured = captured }
    }

    private static func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }

    private static func isCaptured(_ scene: UIWindowScene?) -> Bool {
        guard let scene else { return false }
        switch scene.traitCollection.sceneCaptureState {
        case .active: return true
        case .inactive: return false
        default: return (scene.screen as LegacyCaptureFlag).isCaptured
        }
    }
}

/// The screen-level capture flag, read through a protocol so the fallback compiles without the
/// deprecation warning `UIScreen.isCaptured` carries since the scene trait replaced it.
@MainActor
private protocol LegacyCaptureFlag {
    var isCaptured: Bool { get }
}

extension UIScreen: LegacyCaptureFlag {}
