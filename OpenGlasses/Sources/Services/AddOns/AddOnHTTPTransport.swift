import Foundation

/// One HTTP request a recipe add-on's `http` step makes, after substitution and sandboxing.
struct AddOnHTTPRequest: Equatable, Sendable {
    let method: String
    let url: URL
    /// Already stripped of forbidden headers and control characters (`RecipeSandbox`).
    let headers: [String: String]
    let body: Data?
    /// The most this request may take; the transport should give up after it.
    let timeout: TimeInterval
    /// The most body bytes worth reading; the transport may stop early past it.
    let maxResponseBytes: Int
}

/// What came back for one request. Redirects are **not** followed by the transport: a 3xx comes
/// back with its `Location` so the runner can re-check every hop against the allowlist.
struct AddOnHTTPResponse: Equatable, Sendable {
    let status: Int
    /// Lowercased MIME type without parameters (`application/json`), when the server sent one.
    let mimeType: String?
    let body: Data
    let location: String?

    init(status: Int, mimeType: String?, body: Data, location: String? = nil) {
        self.status = status
        self.mimeType = mimeType
        self.body = body
        self.location = location
    }
}

/// The network edge of the add-on runner. The real implementation (on `BoundedHTTPClient`, with
/// its private/LAN address check, ephemeral session, own User-Agent and no cookies or cache)
/// arrives with the install-and-run phase; tests use a fake. A thrown error is a network failure,
/// which the runner turns into data for the recipe, never into a thrown run.
protocol AddOnHTTPTransport: Sendable {
    func send(_ request: AddOnHTTPRequest) async throws -> AddOnHTTPResponse
}

/// The time source for run and request deadlines — injected so tests never sleep.
protocol AddOnClock: Sendable {
    func now() -> Date
}

struct SystemAddOnClock: AddOnClock {
    func now() -> Date { Date() }
}
