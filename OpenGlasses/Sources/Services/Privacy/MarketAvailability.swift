import Foundation

/// Plan HS P1 item 1 — `MarketAvailabilityPolicy` with this phone's storefront and today's date.
///
/// The storefront is read once per launch through a `StorefrontReader` (StoreKit in the app, a fake
/// in tests), cached, and every answer after that is synchronous. Until the read completes — and
/// whenever it finds no storefront (TestFlight sandboxes, a signed-out App Store) — every capability
/// is `.available`: a legal gate fires on a known market, never on missing data. The policy already
/// says so for a nil code; this type only has to keep the nil until there is something to replace it.
///
/// The read starts at launch (`OpenGlassesApp.init`) and, failing that, on the first question, so a
/// consumer never has to remember to start it.
@MainActor
final class MarketAvailability: ObservableObject {

    static let shared = MarketAvailability()

    /// The storefront's country as ISO 3166-1 alpha-2, once read; nil before then or when unknown.
    @Published private(set) var storefront: String?

    private let reader: any StorefrontReader
    private let now: () -> Date
    private var read: Task<Void, Never>?

    init(reader: any StorefrontReader = StoreKitStorefrontReader(), now: @escaping () -> Date = { Date() }) {
        self.reader = reader
        self.now = now
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

    /// Whether `capability` is offered on this phone's storefront today.
    func availability(of capability: MarketAvailabilityPolicy.Capability) -> MarketAvailabilityPolicy.Availability {
        startReading()
        return MarketAvailabilityPolicy.availability(of: capability, storefront: storefront, at: now())
    }

    /// Whether the Enrolled Faces screen says, ahead of the date, that face recognition is going.
    /// Only on an EEA storefront, and only before the restriction applies; from the date the switch
    /// itself carries the reason.
    var showsFaceRecognitionAdvanceNotice: Bool {
        startReading()
        return Self.showsAdvanceNotice(for: .faceRecognition, storefront: storefront, at: now())
    }

    /// Pure form of `showsFaceRecognitionAdvanceNotice`, so the condition is tested on its own.
    nonisolated static func showsAdvanceNotice(
        for capability: MarketAvailabilityPolicy.Capability,
        storefront: String?,
        at date: Date,
        restrictions: [MarketAvailabilityPolicy.Capability: Date?] = MarketAvailabilityPolicy.restrictedInEEAFrom
    ) -> Bool {
        guard MarketAvailabilityPolicy.isEEA(storefront),
              let from = restrictions[capability] ?? nil else { return false }
        return date < from
    }
}
