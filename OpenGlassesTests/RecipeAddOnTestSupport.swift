import Foundation
@testable import OpenGlasses

/// Shared fakes and fixtures for the recipe add-on tests: an injected clock that only moves when
/// told to, a transport that answers from a handler and records every request, and file builders.

/// A clock that moves only when a test (or the fake transport's latency) advances it.
final class FakeAddOnClock: AddOnClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_794_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Answers each request from `handler`, records it, and advances `clock` by `latency` first.
final class FakeAddOnHTTPTransport: AddOnHTTPTransport, @unchecked Sendable {
    enum Failure: Error { case offline }

    private let lock = NSLock()
    private var recorded: [AddOnHTTPRequest] = []
    private let handler: @Sendable (AddOnHTTPRequest) throws -> AddOnHTTPResponse
    let clock: FakeAddOnClock?
    private var _latency: TimeInterval = 0

    init(clock: FakeAddOnClock? = nil,
         handler: @escaping @Sendable (AddOnHTTPRequest) throws -> AddOnHTTPResponse) {
        self.clock = clock
        self.handler = handler
    }

    /// Always answers `body` as JSON.
    convenience init(clock: FakeAddOnClock? = nil, json body: String, status: Int = 200) {
        self.init(clock: clock) { _ in AddOnHTTPResponse.json(body, status: status) }
    }

    var latency: TimeInterval {
        get { lock.withLock { _latency } }
        set { lock.withLock { _latency = newValue } }
    }

    var requests: [AddOnHTTPRequest] { lock.withLock { recorded } }

    func send(_ request: AddOnHTTPRequest) async throws -> AddOnHTTPResponse {
        lock.withLock { recorded.append(request) }
        clock?.advance(by: latency)
        return try handler(request)
    }

}

extension AddOnHTTPResponse {
    static func json(_ body: String, status: Int = 200) -> AddOnHTTPResponse {
        AddOnHTTPResponse(status: status, mimeType: "application/json", body: Data(body.utf8))
    }

    static func redirect(to location: String, status: Int = 302) -> AddOnHTTPResponse {
        AddOnHTTPResponse(status: status, mimeType: nil, body: Data(), location: location)
    }
}

enum RecipeAddOnFixtures {

    /// The worked example from the format description, verbatim apart from whitespace.
    static let currency = #"""
    {
      "format": "avenkin.addon/1",
      "id": "dev.frankfurter.currency",
      "name": "Currency",
      "version": "1.0.0",
      "author": { "name": "Jo Example", "web": "https://example.org" },
      "description": "Converts money between currencies using daily European Central Bank rates.",
      "icon": "dollarsign.arrow.circlepath",
      "coverage": ["*"],
      "slow": false,
      "permissions": { "network": ["api.frankfurter.dev"] },
      "skills": [{
        "name": "convert_currency",
        "description": "Use when the wearer asks to convert an amount of money, e.g. 'fifty euros in dollars'.",
        "parameters": {
          "amount": { "type": "number", "min": 0, "max": 1000000000, "required": true },
          "from":   { "type": "string", "pattern": "^[A-Z]{3}$", "description": "ISO 4217 code" },
          "to":     { "type": "string", "pattern": "^[A-Z]{3}$" }
        },
        "steps": [
          { "http": { "method": "GET", "as": "fx",
                      "url": "https://api.frankfurter.dev/v1/latest?amount={{amount}}&from={{from}}&to={{to}}" } },
          { "extract": { "from": "fx", "jsonpath": "$.rates.{{to}}", "as": "result" } },
          { "if": { "op": "empty", "var": "result",
                    "then": [ { "say": "I couldn't find a rate for {{to}}." } ],
                    "else": [ { "say": "{{amount}} {{from}} is {{result}} {{to}}." } ] } }
        ]
      }]
    }
    """#

    static var currencyManifest: RecipeAddOnManifest {
        // swiftlint:disable:next force_try
        try! RecipeAddOnManifest.decode(Data(currency.utf8))
    }

    /// A file around `skills`, with the given permissions and any top-level overrides.
    static func file(skills: [[String: Any]],
                     permissions: [String: Any] = ["network": ["api.example.org"]],
                     overrides: [String: Any] = [:]) -> Data {
        var root: [String: Any] = [
            "format": "avenkin.addon/1",
            "id": "org.example.test",
            "name": "Test add-on",
            "version": "1.0.0",
            "author": ["name": "Example Author"],
            "description": "A test add-on.",
            "permissions": permissions,
            "skills": skills,
        ]
        for (key, value) in overrides { root[key] = value }
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    static func skill(name: String = "look_up",
                      description: String = "Use when the wearer asks to look something up.",
                      parameters: [String: Any] = [:],
                      steps: [[String: Any]]) -> [String: Any] {
        var skill: [String: Any] = ["name": name, "description": description, "steps": steps]
        if !parameters.isEmpty { skill["parameters"] = parameters }
        return skill
    }

    static func manifest(skills: [[String: Any]],
                         permissions: [String: Any] = ["network": ["api.example.org"]],
                         overrides: [String: Any] = [:]) throws -> RecipeAddOnManifest {
        try RecipeAddOnManifest.decode(file(skills: skills, permissions: permissions, overrides: overrides))
    }

    static let context = RecipeRunContext(
        now: Date(timeIntervalSince1970: 1_794_052_800),   // 2026-11-07T12:00:00Z
        timeZone: TimeZone(identifier: "UTC")!,
        locale: Locale(identifier: "en_GB"),
        units: .metric,
        location: RecipeLocation(latitude: 51.507_35, longitude: -0.127_76, city: "London", country: "GB"))
}
