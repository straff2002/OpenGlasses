import Foundation

/// Plan HS P1 item 1 — this phone's App Store storefront, read once per launch.
///
/// The storefront is read through a `StorefrontReader` (StoreKit in the app, a fake in tests),
/// cached, and every answer after that is synchronous. Until the read completes — and whenever it
/// finds no storefront (TestFlight sandboxes, a signed-out App Store) — `storefront` is nil, and a
/// consumer treats that as "market unknown", never as a particular market. Today's consumers are
/// the refrigeration units' regional default and the Field Assist settings that show it.
///
/// It also answered the storefront gate for face recognition; that gate went with face
/// recognition on 2026-11-13 (see `MarketAvailabilityPolicy`).
///
/// The read starts at launch (`OpenGlassesApp.init`) and, failing that, on the first question, so a
/// consumer never has to remember to start it.
@MainActor
final class MarketAvailability: ObservableObject {

    static let shared = MarketAvailability()

    /// The storefront's country as ISO 3166-1 alpha-2, once read; nil before then or when unknown.
    @Published private(set) var storefront: String?

    private let reader: any StorefrontReader
    private var read: Task<Void, Never>?

    init(reader: any StorefrontReader = StoreKitStorefrontReader()) {
        self.reader = reader
    }

    /// Start the one read for this launch. Idempotent: a second call does nothing.
    func startReading() {
        guard read == nil else { return }
        let reader = reader
        read = Task { [weak self] in
            let code = await reader.countryCode()
            self?.storefront = code
        }
    }

    /// Wait for the read, starting it if nothing has. For tests and for a caller that would rather
    /// have the answer than the default.
    func refresh() async {
        startReading()
        await read?.value
    }
}
