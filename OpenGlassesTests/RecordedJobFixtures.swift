import Foundation
import XCTest
@testable import OpenGlasses

/// The fixtures of the recorded-session contract (Contracts/fixtures/recorded-session-*,
/// walkthrough-segments-v1, action-events-v1, agreement-v1, cross-reference-v1). Everything in
/// them is made up, and every expected answer was worked out by hand from the contract's rules, so
/// a second implementation can be held to the same answers.
enum RecordedJobFixtures {
    private final class Anchor {}

    static func data(_ name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        #else
        let url = Bundle(for: Anchor.self).url(forResource: name, withExtension: "json")
        #endif
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name).json"))
    }

    static func object(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }

    /// One member of a fixture, written out again as JSON of its own.
    static func json(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(value), options: [.fragmentsAllowed])
    }

    static func decoded<T: Decodable>(_ value: Any?, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: json(value))
    }

    static func cases(_ fixture: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    }

    static func timeline(_ value: Any?) throws -> SessionTimeline { try SessionTimeline.decode(json(value)) }
    static func transcript(_ value: Any?) throws -> TimedTranscript { try TimedTranscript.decode(json(value)) }

    /// The golden job: its timeline and its transcript, as the phone writes them.
    static func goldenTimeline() throws -> SessionTimeline {
        try SessionTimeline.decode(data("recorded-session-timeline-v1"))
    }
    static func goldenTranscript() throws -> TimedTranscript {
        try TimedTranscript.decode(data("recorded-session-transcript-v1"))
    }

    static func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }
}
