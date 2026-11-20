import Foundation

/// One stock system this build can connect to (Plan MM P2): its adapter, the one network route
/// its requests ride, and the few words Settings needs about its key. Everything else about the
/// connection is common and reads from the adapter.
struct StockSystemRegistration: Sendable {
    let adapter: any StockSystemAdapter
    /// The route every request to this system is checked against (`MedicalEgressGuard`).
    let route: NetworkRoute
    /// What the system calls the key the person pastes ("personal access token").
    let keyName: String
    /// Where the key is made, in a sentence or two, before the common list of the permissions the
    /// phone uses. Plain words; no copied vendor text.
    let keySteps: [String]
    /// What a sandbox is called in this system, for the environment choice; nil when it has none.
    let sandboxName: String?

    var connectorID: String { adapter.connectorID }
    var displayName: String { adapter.displayName }
}

/// The stock systems this build offers, by connector id (Plan MM P2). The only common-layer file
/// that names a vendor: adding a system is its adapter folder, its route, and one entry here.
enum StockSystemAdapterRegistry {

    static let all: [StockSystemRegistration] = [
        StockSystemRegistration(
            adapter: SquareStockAdapter(),
            route: .squareStockAPI,
            keyName: String(localized: "personal access token"),
            keySteps: [
                String(localized: "In Square's Developer Console, sign in with the business's Square account and open (or create) an application of the business's own."),
                String(localized: "Copy that application's personal access token: the production one for the business's account, or the sandbox one for a test account."),
                String(localized: "A personal access token can do everything the account can. This phone only makes the calls listed below, and the token stays in this phone's device-only Keychain."),
            ],
            sandboxName: String(localized: "Square sandbox")),
    ]

    /// The connector ids on offer, in order.
    static var connectorIDs: [String] { all.map(\.connectorID) }

    static func registration(for connectorID: String) -> StockSystemRegistration? {
        all.first { $0.connectorID == connectorID }
    }

    static func adapter(for connectorID: String) -> (any StockSystemAdapter)? {
        registration(for: connectorID)?.adapter
    }

    static func route(for connectorID: String) -> NetworkRoute? {
        registration(for: connectorID)?.route
    }
}
