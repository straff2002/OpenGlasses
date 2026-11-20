import Foundation
import XCTest
@testable import OpenGlasses

/// Plan MM P2 — the common connection's test seams: a fixture transport that answers from a
/// closure (Square's fixtures, or anything a test writes) and records what it was handed, an
/// in-memory Keychain for the connection, and a scripted connector for the service.
final class FixtureStockSystemTransport: StockSystemTransport, @unchecked Sendable {

    struct Sent {
        let request: StockSystemRequest
        let destination: StockSystemDestination
        let credential: StockSystemCredential
    }

    private let lock = NSLock()
    private var log: [Sent] = []
    private let respond: (StockSystemRequest) throws -> StockSystemResponse

    init(respond: @escaping (StockSystemRequest) throws -> StockSystemResponse) {
        self.respond = respond
    }

    /// Square's synthetic fixtures (`Contracts/fixtures/square-v2/`), by endpoint and cursor.
    static func square(_ fixtures: SquareFixtures.Transport = SquareFixtures.Transport()) -> FixtureStockSystemTransport {
        FixtureStockSystemTransport { try fixtures.send($0) }
    }

    var sent: [Sent] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func send(_ request: StockSystemRequest, to destination: StockSystemDestination,
              credential: StockSystemCredential) async throws -> StockSystemResponse {
        // The same checks the real transport makes before anything would leave.
        _ = try URLSessionStockSystemTransport.urlRequest(request, to: destination, credential: credential)
        lock.withLock { log.append(Sent(request: request, destination: destination, credential: credential)) }
        return try respond(request)
    }
}

/// An in-memory stand-in for the connection's Keychain items and preferences.
final class MemoryStockSystemStorage {
    var items: [String: Data] = [:]
    var selected: String?
    var pendingErase: [String] = []
    var eraseFails = false
    var readFails = false

    var storage: StockSystemConnectionStore.Storage {
        StockSystemConnectionStore.Storage(
            read: { [unowned self] account in
                if self.readFails { throw KeychainService.KeychainError.unavailable(-25308) }
                return self.items[account]
            },
            write: { [unowned self] data, account in self.items[account] = data },
            erase: { [unowned self] account in
                if self.eraseFails { throw KeychainService.KeychainError.unavailable(-25308) }
                self.items[account] = nil
            },
            selected: { [unowned self] in self.selected },
            setSelected: { [unowned self] in self.selected = $0 },
            pendingErase: { [unowned self] in self.pendingErase },
            setPendingErase: { [unowned self] in self.pendingErase = $0 })
    }
}

/// A connector whose answers a test sets, which counts its calls and can hold a pull until it is
/// let go.
final class ScriptedStockSystemConnector: StockSystemConnector, @unchecked Sendable {

    let capabilities = SquareStockAdapter().capabilities(chosenReason: .waste)
    private let lock = NSLock()
    private var _snapshot: Result<StockSystemSnapshot, Error>
    private var _probe: Result<StockSystemProbe, Error>
    private var _pulls = 0
    private var _probes = 0
    private var _hold = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var locationsResult: Result<[StockSystemLocation], Error> = .success([])

    init(snapshot: Result<StockSystemSnapshot, Error>, probe: Result<StockSystemProbe, Error>) {
        _snapshot = snapshot
        _probe = probe
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var snapshot: Result<StockSystemSnapshot, Error> {
        get { locked { _snapshot } }
        set { locked { _snapshot = newValue } }
    }
    var probeResult: Result<StockSystemProbe, Error> {
        get { locked { _probe } }
        set { locked { _probe = newValue } }
    }
    var pulls: Int { locked { _pulls } }
    var probes: Int { locked { _probes } }
    var heldCount: Int { locked { waiting.count } }

    /// While set, a pull waits until `release()`.
    func hold() { locked { _hold = true } }

    func release() {
        let held: [CheckedContinuation<Void, Never>] = locked {
            _hold = false
            let all = waiting
            waiting = []
            return all
        }
        held.forEach { $0.resume() }
    }

    func locations() async throws -> [StockSystemLocation] { try locationsResult.get() }

    func pullSnapshot(locationIDs: [String], pulledAt: Date) async throws -> StockSystemSnapshot {
        let hold: Bool = locked { _pulls += 1; return _hold }
        if hold {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = locked {
                    if _hold { waiting.append(continuation); return false }
                    return true
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try snapshot.get()
    }

    func probe() async throws -> StockSystemProbe {
        locked { _probes += 1 }
        return try probeResult.get()
    }

    func apply(_ steps: [PartsUsedWritePlan.Step], confirmedAt: Date) async throws -> StockSystemReadBack {
        StockSystemReadBack(applied: [])
    }

    func readBack(_ plan: PartsUsedWritePlan, queuedAt: Date) async throws -> StockSystemReadBack {
        StockSystemReadBack(applied: [])
    }
}

enum StockSystemConnectionSamples {

    /// A key-shaped value made at run time, so no secret-looking literal is in the source.
    static func key(_ tag: String = "a") -> String {
        "TESTKEY-" + String(repeating: tag, count: 4) + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    static let square = StockSystemAdapterRegistry.registration(for: "square")!

    static let main = StockSystemLocation(id: "LOC-FIX-MAIN", name: "Main Street", locationClass: .base)
    static let van = StockSystemLocation(id: "LOC-FIX-VAN", name: "Van 1", locationClass: .van)

    /// A snapshot as Square's connector would make it, at `asOf`.
    static func snapshot(asOf: Date = StockSystemSamples.pulledAt, part: String = "ZX-1") -> StockSystemSnapshot {
        let builder = StockSystemSnapshotBuilder(source: StockSystemSource(connectorID: "square", displayName: "Square"),
                                                 unitMap: StockSystemSamples.unitMap)
        return builder.build(locations: [StockSystemRawLocation(id: main.id, name: main.name, locationClass: "base")],
                             rows: [StockSystemSamples.row("ITEM-1", part: part, [(main.id, "3")])],
                             pulledAt: asOf).snapshot
    }

    static func probe(missing: String? = nil) -> StockSystemProbe {
        StockSystemProbe(locations: [main, van], checks: [.init(purpose: .stock, missingScope: missing),
                                                          .init(purpose: .catalogue, missingScope: nil)])
    }
}
