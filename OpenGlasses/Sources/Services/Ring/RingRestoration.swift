import Foundation

/// CoreBluetooth state restoration for the ring's link (Plan MZ decision 3, follow-up). Pure.
///
/// The ring's central is created with `restoreIdentifier`. If iOS ends Avenkin to free memory
/// while a connect to the paired ring is pending or the link is up, iOS keeps that connection
/// and relaunches Avenkin in the background when the ring has something to say. On relaunch the
/// central, made again with the same identifier, is handed the ring back
/// (`centralManager(_:willRestoreState:)`). A wearer who force-quits the app turns this off until
/// they open it again; iOS does that, and no app can change it.
///
/// Forgetting the ring, or turning the ring support off, cancels the connection, and then there is
/// nothing for iOS to relaunch the app for.
enum RingRestoration {

    /// The ring central's restore identifier. Never change it: iOS matches a relaunch to the
    /// central by this string, so a new one would strand the connection an older build left.
    static let restoreIdentifier = "ring-central"

    /// Whether iOS launched the app for the ring's link: the identifiers it passes in the
    /// `.bluetoothCentrals` launch option.
    static func launchedForRing(centrals: [String]?) -> Bool {
        centrals?.contains(restoreIdentifier) == true
    }

    /// The restored ring to take back: the paired one, and only that one. A restored peripheral
    /// that isn't the paired ring (a ring forgotten while the app was not running) is not adopted,
    /// and the transport cancels it so iOS stops holding it.
    static func peripheralToAdopt(restored: [UUID], paired: UUID?) -> UUID? {
        guard let paired, restored.contains(paired) else { return nil }
        return paired
    }

    /// The restored state as a log token, never the identifier.
    enum LinkState: String, Equatable, Sendable {
        case connected, connecting, none
    }
}
