import Foundation

/// A stock system over the common transport (Plan MM P2): any adapter, driven through
/// `StockSystemPlanDriver`, so every operation has the same loop, request budget and endpoint
/// check whatever the system. It names no vendor; the adapter is all that differs.
///
/// Writes and read-backs are wired for the queued sink (P4) and are not called by anything yet.
struct StockSystemHTTPConnector: StockSystemConnector {

    let adapter: any StockSystemAdapter
    let destination: StockSystemDestination
    let transport: any StockSystemTransport
    let credential: StockSystemCredential
    /// The organisation's reason for parts used and not sold, from the connection's settings.
    let chosenReason: StockAdjustmentReason?
    /// The account as the person sees it, for the snapshot's source.
    let accountLabel: String?
    let pricesEnabled: Bool
    let now: @Sendable () -> Date

    init(adapter: any StockSystemAdapter, destination: StockSystemDestination, transport: any StockSystemTransport,
         credential: StockSystemCredential, chosenReason: StockAdjustmentReason? = nil, accountLabel: String? = nil,
         pricesEnabled: Bool = StockSystemPolicy.pricesEnabledByDefault, now: @escaping @Sendable () -> Date = { Date() }) {
        self.adapter = adapter
        self.destination = destination
        self.transport = transport
        self.credential = credential
        self.chosenReason = chosenReason
        self.accountLabel = accountLabel
        self.pricesEnabled = pricesEnabled
        self.now = now
    }

    var capabilities: StockSystemCapabilities { adapter.capabilities(chosenReason: chosenReason) }

    func locations() async throws -> [StockSystemLocation] {
        try await run(adapter.locationsPlan())
    }

    /// A whole snapshot of the chosen locations, with what the adapter skipped.
    func pull(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshotPull {
        try await run(adapter.snapshotPlan(locationIDs: locationIDs, pulledAt: pulledAt, accountLabel: accountLabel,
                                           pricesEnabled: pricesEnabled))
    }

    func pullSnapshot(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshot {
        try await pull(locationIDs: locationIDs, pulledAt: pulledAt).snapshot
    }

    func probe() async throws -> StockSystemProbe {
        let locations = try await locations()
        let checks = try await run(StockSystemProbePlan(adapter: adapter, requests: try adapter.probeRequests()))
        return StockSystemProbe(locations: locations, checks: checks)
    }

    func apply(_ steps: [PartsUsedWritePlan.Step], confirmedAt: Date) async throws -> StockSystemReadBack {
        let writes = try adapter.writeRequests(for: steps, occurredAt: confirmedAt, now: now())
        var applied = Set<String>()
        var mismatched: [StockSystemReadBack.Mismatch] = []
        for write in writes {
            guard adapter.allowedEndpoints.contains(write.request.endpoint) else { throw StockSystemRequestRefusal.offList }
            let accepted = try adapter.acceptedWrite(try await send(write.request), for: write)
            applied.formUnion(accepted.applied)
            mismatched += accepted.mismatched
        }
        return StockSystemReadBack(applied: applied, mismatched: mismatched)
    }

    func readBack(_ plan: PartsUsedWritePlan, queuedAt: Date) async throws -> StockSystemReadBack {
        try await run(adapter.readBackPlan(plan, queuedAt: queuedAt))
    }

    // MARK: - Pieces

    private func run<Output>(_ plan: any StockSystemPullPlan<Output>) async throws -> Output {
        try await StockSystemPlanDriver.run(plan, allowed: adapter.allowedEndpoints) { try await send($0) }
    }

    private func send(_ request: StockSystemRequest) async throws -> StockSystemResponse {
        try Task.checkCancellation()
        return try await transport.send(request, to: destination, credential: credential)
    }
}

/// Test connection's reads as a plan (Plan MM P2): each of the adapter's probe requests in turn,
/// recording a missing permission per kind of read instead of failing, and failing on anything
/// else. Reads only: a write endpoint is refused when the plan is made.
struct StockSystemProbePlan: StockSystemPullPlan {

    let adapter: any StockSystemAdapter
    private let requests: [StockSystemRequest]
    private var index = 0
    private var checks: [StockSystemProbe.Check] = []
    private(set) var result: [StockSystemProbe.Check]?

    init(adapter: any StockSystemAdapter, requests: [StockSystemRequest]) throws {
        guard requests.allSatisfy({ !$0.endpoint.writes && adapter.allowedEndpoints.contains($0.endpoint) }) else {
            throw StockSystemRequestRefusal.notAllowed
        }
        self.adapter = adapter
        self.requests = requests
        if requests.isEmpty { result = [] }
    }

    mutating func next() throws -> StockSystemRequest? {
        guard result == nil, index < requests.count else { return nil }
        return requests[index]
    }

    mutating func consume(_ response: StockSystemResponse) throws {
        guard result == nil, index < requests.count else { throw StockSystemFailure.malformedResponse }
        let endpoint = requests[index].endpoint
        if let failure = adapter.failure(response, endpoint: endpoint) {
            guard case .missingScope(let scope) = failure else { throw failure }
            checks.append(.init(purpose: endpoint.purpose, missingScope: scope))
        } else {
            checks.append(.init(purpose: endpoint.purpose, missingScope: nil))
        }
        index += 1
        if index == requests.count { result = checks }
    }
}

/// The permissions a key needs, read from the adapter's endpoints (Plan MM §3): what Settings'
/// "How to make a key" lists. Reads always; the writes and the read-back only while sending back
/// is on.
enum StockSystemKeyPermissions {

    /// The scopes the phone's reads use, in the adapter's order, each once.
    static func reading(_ adapter: any StockSystemAdapter) -> [String] {
        unique(adapter.allowedEndpoints.filter { [.locations, .catalogue, .stock].contains($0.purpose) })
    }

    /// The scopes sending back adds to `reading`: the write, and the history read-back uses.
    static func sendingBack(_ adapter: any StockSystemAdapter) -> [String] {
        let read = Set(reading(adapter))
        return unique(adapter.allowedEndpoints.filter { [.write, .history].contains($0.purpose) }).filter { !read.contains($0) }
    }

    private static func unique(_ endpoints: [StockSystemEndpoint]) -> [String] {
        var seen = Set<String>()
        return endpoints.compactMap(\.scope).filter { seen.insert($0).inserted }
    }
}
