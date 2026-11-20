import CryptoKit
import Foundation

// The vendor-neutral seam a stock system plugs into (Plan MM P1). Everything here is common: a
// system adds only a thin adapter (`StockSystemAdapter`) that builds its requests, decodes its
// responses, maps its units, declares what it can take back, and recognises its own writes when
// it reads them back. The connection, the Keychain, the transport, the store, the pull triggers,
// the sink and the confirmation are the common layer's, and none of them needs to know which
// system it is talking to. Nothing in this folder names a vendor; each adapter lives in a
// subfolder of its own.

/// The HTTP methods an adapter may use: a closed list, so a request can never be a delete or a
/// replace by accident.
enum StockSystemHTTPMethod: String, Hashable, Sendable, CaseIterable {
    case get = "GET"
    case post = "POST"
}

/// One endpoint an adapter declares: the method, the path, what it is for and the system's own
/// name for the permission it needs. An adapter's endpoints are a closed list
/// (`StockSystemAdapter.allowedEndpoints`); a request can only be made for one of them, and the
/// transport refuses anything else.
struct StockSystemEndpoint: Hashable, Sendable, CustomStringConvertible {

    /// What a call to the endpoint does. Only `write` changes anything in the system.
    enum Purpose: String, Hashable, Sendable, CaseIterable {
        /// The system's locations, for "Which stock is here?".
        case locations
        /// The system's catalogue: names, part numbers, units.
        case catalogue
        /// Current figures.
        case stock
        /// Past changes, for a read-back.
        case history
        /// The one kind of write: what `PartsUsedWritePlan` holds.
        case write
    }

    let method: StockSystemHTTPMethod
    /// The path, starting with `/`. A segment written `{name}` is a parameter the request fills
    /// with a checked identifier; every other character is fixed.
    let path: String
    let purpose: Purpose
    /// The system's own name for the permission the endpoint needs, said when the key lacks it.
    let scope: String?

    init(_ method: StockSystemHTTPMethod, _ path: String, purpose: Purpose, scope: String?) {
        self.method = method
        self.path = path
        self.purpose = purpose
        self.scope = scope
    }

    var writes: Bool { purpose == .write }

    var description: String { "\(method.rawValue) \(path)" }
}

/// Why a request value could not be made. Each is a programming or data error, never something
/// to retry.
enum StockSystemRequestRefusal: Error, Equatable, Sendable {
    /// The endpoint is not on the adapter's list.
    case offList
    /// A path parameter is missing, unexpected or not a plain identifier.
    case badParameter
    /// A header the request may not carry (credentials, cookies, the host), or one with control
    /// characters.
    case forbiddenHeader
    /// A body on a `GET`, or a body over `StockSystemRequest.maximumBodyBytes`.
    case badBody
    /// The write is not one the adapter can make: not one of the plan's kinds this system takes,
    /// a reason it does not keep, a quantity it cannot hold, or more than it accepts at once.
    case notAllowed
}

/// One request as an adapter builds it: an allowed endpoint, its filled path, query items, a JSON
/// body and the non-secret headers the system wants (a version header, say). Pure.
///
/// It has no host and no credentials. The common transport adds the pinned host for the
/// connection's environment and the key, and checks the endpoint against the adapter's list again
/// before anything leaves the phone. Its descriptions name the method, the path and the size of
/// the body, never the body or a header's value.
struct StockSystemRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// A body larger than this is refused before it is sent.
    static let maximumBodyBytes = 1_000_000

    /// Header names a request may never carry, compared without regard to case. The transport adds
    /// the credential itself.
    static let forbiddenHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "host", "x-api-key", "api-key",
    ]

    let endpoint: StockSystemEndpoint
    /// The endpoint's path with its parameters filled.
    let path: String
    let query: [URLQueryItem]
    /// JSON bytes, or nil.
    let body: Data?
    /// Non-secret headers, by name.
    let headers: [String: String]

    var method: StockSystemHTTPMethod { endpoint.method }

    /// A request for `endpoint`, which must be in `allowed`. Each `{name}` segment of the path is
    /// filled from `parameters`, which must name exactly those segments with plain identifiers.
    init(_ endpoint: StockSystemEndpoint, allowed: [StockSystemEndpoint], parameters: [String: String] = [:],
         query: [URLQueryItem] = [], body: Data? = nil, headers: [String: String] = [:]) throws {
        guard allowed.contains(endpoint) else { throw StockSystemRequestRefusal.offList }
        self.path = try Self.fill(endpoint.path, parameters)
        if let body {
            guard endpoint.method != .get, body.count <= Self.maximumBodyBytes else { throw StockSystemRequestRefusal.badBody }
        }
        for (name, value) in headers {
            let lowered = name.lowercased()
            guard !Self.forbiddenHeaderNames.contains(lowered), !name.isEmpty, name.count <= 64,
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
                  value.count <= 256, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw StockSystemRequestRefusal.forbiddenHeader }
        }
        self.endpoint = endpoint
        self.query = query
        self.body = body
        self.headers = headers
    }

    /// The request's URL on `host` (a bare host name such as the adapter's production host), over
    /// HTTPS only. Nil when the host is not a plain host name.
    func url(host: String) -> URL? {
        guard !host.isEmpty, host.count <= 253,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." })
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    /// The body as a JSON object, for checks; nil when there is none or it is not an object.
    var jsonBody: [String: Any]? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var description: String {
        let size = body.map { " (\($0.count)-byte body)" } ?? ""
        return "\(method.rawValue) \(path)\(size)"
    }

    var debugDescription: String { description }

    /// What `dump` and the debugger show: never a header's value or the body.
    var customMirror: Mirror {
        Mirror(self, children: [
            "endpoint": endpoint.description,
            "path": path,
            "query": query.map(\.name),
            "headers": headers.keys.sorted(),
            "bodyBytes": body?.count ?? 0,
        ], displayStyle: .struct)
    }

    static func == (lhs: StockSystemRequest, rhs: StockSystemRequest) -> Bool {
        lhs.endpoint == rhs.endpoint && lhs.path == rhs.path && lhs.query == rhs.query && lhs.body == rhs.body
            && lhs.headers == rhs.headers
    }

    /// An identifier fit for a path segment: 1–128 letters, digits, `-`, `_` or `.`, and not `.`
    /// or `..`.
    static func isPlainIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= StockSystemPolicy.Cap.identifier && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private static func fill(_ template: String, _ parameters: [String: String]) throws -> String {
        guard template.hasPrefix("/") else { throw StockSystemRequestRefusal.badParameter }
        var used = Set<String>()
        let segments = try template.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            guard segment.hasPrefix("{"), segment.hasSuffix("}"), segment.count > 2 else { return String(segment) }
            let name = String(segment.dropFirst().dropLast())
            guard let value = parameters[name], isPlainIdentifier(value) else { throw StockSystemRequestRefusal.badParameter }
            used.insert(name)
            return value
        }
        guard used == Set(parameters.keys) else { throw StockSystemRequestRefusal.badParameter }
        return segments.joined(separator: "/")
    }
}

/// What came back for a request: the status, the body and the headers. The transport caps the
/// body before it gets here.
struct StockSystemResponse: Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    var succeeded: Bool { (200..<300).contains(status) }

    /// A header's value, matched without regard to case.
    func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

/// The production and test hosts an adapter talks to: data only. The common transport pins them.
struct StockSystemHosts: Equatable, Sendable {
    let production: String
    let sandbox: String?
}

/// One operation that may take several requests (a paged list, a few lookups in turn), as a small
/// pure state machine. The common driver loops `while let request = try plan.next() { try
/// plan.consume(send(request)) }` and reads `result`, so it never needs to know the system's
/// paging or its response shapes.
///
/// `next()` gives the next request, or nil when the plan has everything it needs (or has failed,
/// in which case `consume` already threw). `consume` reads one response: a status the plan cannot
/// use throws a `StockSystemFailure`.
protocol StockSystemPullPlan<Output> {
    associatedtype Output
    mutating func next() throws -> StockSystemRequest?
    mutating func consume(_ response: StockSystemResponse) throws
    var result: Output? { get }
}

/// A batch of writes as one request, and the steps it carries, so the response can be checked
/// against exactly those steps.
struct StockSystemWriteRequest: Equatable, Sendable {
    let request: StockSystemRequest
    let steps: [PartsUsedWritePlan.Step]
    /// The system-side idempotency key for the whole request (`StockSystemIdempotency.batchKey`).
    let batchKey: String
}

/// A pulled snapshot, with what the adapter skipped before the builder saw it, for the person and
/// the support report.
struct StockSystemSnapshotPull: Equatable, Sendable {

    struct Skipped: Equatable, Sendable {
        /// Objects the system marked deleted.
        var deleted = 0
        /// Items not tracked at any chosen location.
        var untracked = 0
        /// Items not offered at any chosen location.
        var notHere = 0
        /// Objects or figures that could not be read, or name nothing the pull holds.
        var unreadable = 0

        var total: Int { deleted + untracked + notHere + unreadable }
    }

    let build: StockSystemSnapshotBuilder.Result
    let skipped: Skipped

    var snapshot: StockSystemSnapshot { build.snapshot }
}

/// A stock system, as the common layer drives it (Plan MM P1). Pure: no network, no key, no
/// store. An adapter supplies five things, and only these:
///
/// 1. **Requests**: its endpoints (`allowedEndpoints`) and every request built from them.
/// 2. **Decoding**: its responses read into the common types, closed and bounded.
/// 3. **Units**: its table onto the phone's closed list (`unitMap`).
/// 4. **Capabilities**: what it can take back (`capabilities(chosenReason:)`).
/// 5. **Read-back**: recognising its own writes (`readBackPlan`, `acceptedWrite`).
///
/// It never sees the key: the transport adds it to a request the adapter built without one.
protocol StockSystemAdapter: Sendable {
    /// A lowercase token, the connection's and a job reference's `system`.
    var connectorID: String { get }
    /// How people name the system: "in <name>".
    var displayName: String { get }
    var hosts: StockSystemHosts { get }
    /// Every endpoint the adapter may call, and so every request it can build.
    var allowedEndpoints: [StockSystemEndpoint] { get }
    /// The system's unit words that map onto the phone's units; anything else is not kept.
    var unitMap: StockSystemUnitMap { get }

    /// What the system can take back, with the organisation's chosen reason.
    func capabilities(chosenReason: StockAdjustmentReason?) -> StockSystemCapabilities

    /// The system's locations, for "Which stock is here?".
    func locationsPlan() -> any StockSystemPullPlan<[StockSystemLocation]>

    /// A whole snapshot of the chosen locations' stock.
    func snapshotPlan(locationIDs: [String], pulledAt: Date, accountLabel: String?,
                      pricesEnabled: Bool) -> any StockSystemPullPlan<StockSystemSnapshotPull>

    /// The plan's steps as the system's write requests, in order. `occurredAt` is when the person
    /// confirmed the batch and `now` the time of sending, for a system that limits how old a write
    /// may say it is. Throws `StockSystemRequestRefusal.notAllowed` for a step the system cannot take.
    func writeRequests(for steps: [PartsUsedWritePlan.Step], occurredAt: Date, now: Date) throws -> [StockSystemWriteRequest]

    /// What a write's response says was applied. Throws when the outcome is not certain, so the
    /// caller reads back before trying again.
    func acceptedWrite(_ response: StockSystemResponse, for write: StockSystemWriteRequest) throws -> StockSystemReadBack

    /// Which of the plan's steps the system already shows, read from its history since the batch
    /// was queued.
    func readBackPlan(_ plan: PartsUsedWritePlan, queuedAt: Date) -> any StockSystemPullPlan<StockSystemReadBack>

    /// The failure a response stands for, or nil when it succeeded.
    func failure(_ response: StockSystemResponse, endpoint: StockSystemEndpoint) -> StockSystemFailure?
}

/// Runs a plan against a send function: the loop every operation shares. Pure apart from `send`.
enum StockSystemPlanDriver {

    /// The most requests one operation may make, whatever its plan says.
    static let requestBudget = 250

    static func run<Output>(_ plan: any StockSystemPullPlan<Output>, allowed: [StockSystemEndpoint],
                            send: (StockSystemRequest) async throws -> StockSystemResponse) async throws -> Output {
        var plan = plan
        var sent = 0
        while let request = try plan.next() {
            guard allowed.contains(request.endpoint) else { throw StockSystemRequestRefusal.offList }
            sent += 1
            guard sent <= requestBudget else { throw StockSystemFailure.tooLarge }
            try plan.consume(try await send(request))
        }
        guard let result = plan.result else { throw StockSystemFailure.malformedResponse }
        return result
    }
}

/// The common rules for a system-side idempotency key and a write's time.
enum StockSystemIdempotency {

    /// Lower-case SHA-256 hex over the sorted step keys, each followed by one zero byte: the same
    /// remaining set always gives the same key, so a rebuilt batch is recognised as the one sent.
    static func batchKey(stepKeys: [String]) -> String {
        var bytes = Data()
        for key in stepKeys.sorted() {
            bytes.append(contentsOf: Array(key.utf8))
            bytes.append(0)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The time a write says it happened, for a system that refuses one older than `maximumAge`:
    /// the confirmation time while it is younger than that, otherwise the time of sending. A
    /// confirmation in the future (a clock out of step) is the time of sending too. Whole seconds.
    static func occurredAt(confirmedAt: Date, now: Date, maximumAge: TimeInterval) -> Date {
        let chosen = (confirmedAt > now || now.timeIntervalSince(confirmedAt) > maximumAge) ? now : confirmedAt
        return Date(timeIntervalSince1970: chosen.timeIntervalSince1970.rounded(.down))
    }
}

/// An element that is dropped, not thrown, when it cannot be read: for an adapter's closed
/// decoding of a list.
struct StockSystemLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
