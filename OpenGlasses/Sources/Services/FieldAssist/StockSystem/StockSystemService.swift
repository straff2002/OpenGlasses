import Foundation
import Combine

/// The connected stock system, as the app drives it (Plan MM P2): Test connection, the locations
/// for "Which stock is here?", and the pulls that keep the last good snapshot fresh.
///
/// Pulls happen when the app comes to the foreground and when the Stock screen opens, each at most
/// every `automaticPullInterval`, and on pull-to-refresh, which always pulls. There is no background
/// fetch. One pull at a time: a second caller waits for the one under way. A failed pull keeps the
/// last good snapshot and says why in the system's words (`StockSystemFailure`). Under Medical
/// Local Only nothing is pulled and the snapshot is kept with its age. The office route ceiling
/// erases every key and retires every snapshot. Vendor-neutral: the system comes from the
/// connection and `StockSystemAdapterRegistry`.
@MainActor
final class StockSystemService: ObservableObject {

    /// Makes the connector for a connection; nil when the connection cannot be sent anywhere (no
    /// host for its environment, a key the transport would refuse).
    typealias ConnectorFactory = @MainActor (StockSystemConnectionRecord, StockSystemRegistration,
                                             StockAdjustmentReason?) -> (any StockSystemConnector)?

    /// The least time between automatic pulls (Plan MM §2).
    nonisolated static let automaticPullInterval: TimeInterval = 10 * 60

    let connection: StockSystemConnectionStore
    let store: StockSystemSnapshotStore
    private let registry: (String) -> StockSystemRegistration?
    private let makeConnector: ConnectorFactory
    private let now: () -> Date
    private let medicalBlocks: (NetworkRoute) -> Bool
    private let placeName: @MainActor () -> String?

    @Published private(set) var pulling = false
    @Published private(set) var testing = false
    @Published private(set) var loadingLocations = false
    /// Why the last pull did not refresh the figures, in a sentence; nil after a good pull.
    @Published private(set) var pullMessage: String?
    /// What Test connection found, in one line.
    @Published private(set) var connectionLine: String?
    /// The system's locations, as Test connection or a reload last read them.
    @Published private(set) var availableLocations: [StockSystemLocation] = []
    /// When an automatic pull last started, for the interval.
    private(set) var lastAttempt: Date?

    private var inFlight: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(connection: StockSystemConnectionStore, store: StockSystemSnapshotStore,
         registry: @escaping (String) -> StockSystemRegistration? = { StockSystemAdapterRegistry.registration(for: $0) },
         now: @escaping () -> Date = { Date() },
         medicalBlocks: @escaping (NetworkRoute) -> Bool = { MedicalEgressGuard.blocks($0) },
         placeName: @escaping @MainActor () -> String? = { VanStockStore.shared.van?.name },
         makeConnector: @escaping ConnectorFactory) {
        self.connection = connection
        self.store = store
        self.registry = registry
        self.now = now
        self.medicalBlocks = medicalBlocks
        self.placeName = placeName
        self.makeConnector = makeConnector
        // Settings and the Stock screen observe the service; pass the connection's and the
        // store's changes through.
        connection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    /// The app's service: the Keychain connection, the store in Application Support and the
    /// common transport.
    static func forApp() -> StockSystemService {
        StockSystemService(connection: StockSystemConnectionStore(), store: StockSystemSnapshotStore(),
                           makeConnector: httpConnector(transport: URLSessionStockSystemTransport()))
    }

    /// Connectors over the common transport.
    static func httpConnector(transport: any StockSystemTransport) -> ConnectorFactory {
        { record, registration, reason in
            guard let destination = StockSystemDestination(adapter: registration.adapter, route: registration.route,
                                                           environment: record.environment),
                  let credential = StockSystemCredential(record.key) else { return nil }
            return StockSystemHTTPConnector(adapter: registration.adapter, destination: destination, transport: transport,
                                            credential: credential, chosenReason: reason, accountLabel: record.accountLabel)
        }
    }

    // MARK: - What is in force

    var registration: StockSystemRegistration? { registry(connection.selectedConnectorID) }
    var displayName: String { registration?.displayName ?? String(localized: "the stock system") }
    var isRunning: Bool { connection.isRunning && registration != nil }
    var isBlockedByMedical: Bool { registration.map { medicalBlocks($0.route) } ?? false }

    /// The chosen system's last good snapshot, kept with its age whatever happens to a pull.
    var snapshot: StockSystemSnapshot? { store.snapshot(for: connection.selectedConnectorID) }

    /// "From <system> at 09:10", or nil with no snapshot.
    var statusLine: String? {
        snapshot.map { Self.statusLine(system: $0.source.displayName, asOf: $0.asOf, now: now()) }
    }

    nonisolated static func statusLine(system: String, asOf: Date, now: Date, calendar: Calendar = .current) -> String {
        let when = StockSystemAnswerComposer(now: now, calendar: calendar, system: system).time(asOf)
        let isClock = when.count == 5 && when.first?.isNumber == true
        return isClock ? "From \(system) at \(when)" : "From \(system), \(when)"
    }

    // MARK: - Pull triggers

    /// The app came to the foreground.
    func appBecameActive() async { await pull(force: false) }
    /// The Stock screen opened.
    func stockScreenOpened() async { await pull(force: false) }
    /// Pull-to-refresh on the Stock screen.
    func refresh() async { await pull(force: true) }

    /// Pull the chosen locations' snapshot. Automatic pulls wait out the interval; a forced one
    /// does not. While one is under way every caller waits for it instead of starting another.
    func pull(force: Bool) async {
        enforceRoute()
        if let inFlight {
            await inFlight.value
            return
        }
        guard isRunning, let record = connection.record, let registration, !record.locationIDs.isEmpty else { return }
        if !force, let last = lastAttempt, now().timeIntervalSince(last) < Self.automaticPullInterval { return }
        guard !medicalBlocks(registration.route) else {
            pullMessage = MedicalEgressRefusal.userMessage
            return
        }
        guard let connector = makeConnector(record, registration, connection.reason) else { return }
        lastAttempt = now()
        pulling = true
        // The task clears itself when it ends, so a caller that waited on it finds no pull under
        // way once it resumes.
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPull(connector, record: record, system: registration.displayName)
            self.inFlight = nil
            self.pulling = false
        }
        inFlight = task
        await task.value
    }

    private func runPull(_ connector: any StockSystemConnector, record: StockSystemConnectionRecord, system: String) async {
        do {
            let snapshot = try await connector.pullSnapshot(locationIDs: record.locationIDs, pulledAt: now())
            // A key, an environment or a choice of locations that changed meanwhile makes this
            // reply someone else's: it is not kept.
            guard isCurrent(record) else { return }
            pullMessage = store.replace(snapshot) ? nil : String(localized: "The figures from \(system) couldn't be saved on this phone. The last ones are still used.")
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(record) else { return }
            pullMessage = Self.sentence(error, system: system)
        }
    }

    private func isCurrent(_ record: StockSystemConnectionRecord) -> Bool {
        guard isRunning, let current = connection.record else { return false }
        return current.generation == record.generation && current.environment == record.environment
            && current.locationIDs == record.locationIDs
    }

    // MARK: - Test connection and the locations

    /// Reads only: the locations, then the smallest read of each kind the snapshot needs, then one
    /// line. With no location chosen yet, the one whose name matches the place's is chosen when
    /// exactly one does. A good test pulls at once.
    func testConnection() async {
        guard !testing else { return }
        enforceRoute()
        guard isRunning, let record = connection.record, let registration else {
            connectionLine = nil
            return
        }
        guard !medicalBlocks(registration.route) else {
            connectionLine = MedicalEgressRefusal.userMessage
            return
        }
        guard let connector = makeConnector(record, registration, connection.reason) else {
            connectionLine = StockSystemFailure.unauthorized(.invalid).sentence(system: registration.displayName)
            return
        }
        testing = true
        defer { testing = false }
        do {
            let probe = try await connector.probe()
            guard isCurrent(record) else { return }
            availableLocations = probe.locations
            if record.locations.isEmpty, let match = Self.preselect(probe.locations, placeName: placeName()) {
                try? connection.chooseLocations([match])
            }
            connectionLine = probe.line(system: registration.displayName, sendingBack: connection.sendingBack)
            if probe.passed {
                testing = false
                await pull(force: true)
            }
        } catch {
            guard isCurrent(record) else { return }
            connectionLine = Self.sentence(error, system: registration.displayName)
        }
    }

    /// Read the system's locations again, for "Which stock is here?".
    func loadLocations() async {
        guard !loadingLocations, isRunning, let record = connection.record, let registration,
              !medicalBlocks(registration.route), let connector = makeConnector(record, registration, connection.reason)
        else { return }
        loadingLocations = true
        defer { loadingLocations = false }
        do {
            let locations = try await connector.locations()
            guard isCurrent(record) else { return }
            availableLocations = locations
        } catch {
            guard isCurrent(record) else { return }
            connectionLine = Self.sentence(error, system: registration.displayName)
        }
    }

    /// Change "Which stock is here?". A different choice makes the snapshot someone else's, so it
    /// is retired and the new choice pulled.
    func chooseLocations(_ locations: [StockSystemLocation]) async throws {
        let before = connection.record?.locationIDs
        try connection.chooseLocations(locations)
        guard connection.record?.locationIDs != before else { return }
        if let inFlight {
            inFlight.cancel()
            await inFlight.value
        }
        store.retire(connection.selectedConnectorID)
        lastAttempt = nil
        await pull(force: true)
    }

    /// The location of `locations` whose name is the place's name, when exactly one is.
    nonisolated static func preselect(_ locations: [StockSystemLocation], placeName: String?) -> StockSystemLocation? {
        guard let name = placeName.map(normalised), !name.isEmpty else { return nil }
        let matches = locations.filter { normalised($0.name) == name }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated private static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Ending a connection

    /// A new key was saved: what the old one read is not this key's.
    func keyChanged() {
        stopWork()
        store.retire(connection.selectedConnectorID)
    }

    /// Remove connection: the key, the choices and the snapshot.
    func remove() {
        stopWork()
        let id = connection.selectedConnectorID
        try? connection.remove(id)
        store.retire(id)
        pullMessage = connection.problem
    }

    /// Every connection and every snapshot: the phone left its organisation.
    func removeAll() {
        stopWork()
        try? connection.removeAll()
        store.retireAll()
        pullMessage = connection.problem
    }

    /// The office route ceiling (`organizationFieldServiceRoute = office`): the office connects the
    /// firm's systems, so every key here is erased and every snapshot retired (Plan MM §4).
    func enforceRoute() {
        guard connection.officeRoute else { return }
        guard !connection.records.isEmpty || !store.snapshots.isEmpty || inFlight != nil || connection.problem != nil
        else { return }
        stopWork()
        try? connection.removeAll()
        store.retireAll()
    }

    private func stopWork() {
        inFlight?.cancel()
        availableLocations = []
        pullMessage = nil
        connectionLine = nil
        lastAttempt = nil
    }

    // MARK: - Sentences

    /// What the person is told when a call failed, in the system's words.
    nonisolated static func sentence(_ error: Error, system: String) -> String {
        if let failure = error as? StockSystemFailure { return failure.sentence(system: system) }
        if error is MedicalEgressRefusal { return MedicalEgressRefusal.userMessage }
        if error is StockSystemTransportRefusal || error is StockSystemRequestRefusal {
            return String(localized: "The phone stopped a request to \(system) that it shouldn't send. Nothing was sent.")
        }
        return StockSystemFailure.unreachable.sentence(system: system)
    }
}
