import XCTest
@testable import OpenGlasses

/// Plan MZ "Privacy and safety" — nothing in `Services/Ring/` hands `PrivacyLog` a reading, an
/// address, an identifier or a packet's bytes, and nothing there logs any other way.
final class RingPrivacyScrapeTests: XCTestCase {

    private static var ringSources: [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("OpenGlasses/Sources/Services/Ring")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return (name, text)
        }
    }

    /// Every `PrivacyLog` call in the folder, joined across its lines.
    private static func logCalls(in text: String) -> [String] {
        var calls: [String] = []
        var remaining = text[...]
        while let start = remaining.range(of: "PrivacyLog.") {
            var depth = 0
            var end = start.upperBound
            var opened = false
            while end < remaining.endIndex {
                let character = remaining[end]
                if character == "(" { depth += 1; opened = true }
                if character == ")" { depth -= 1 }
                end = remaining.index(after: end)
                if opened && depth == 0 { break }
            }
            calls.append(String(remaining[start.lowerBound..<end]))
            remaining = remaining[end...]
        }
        return calls
    }

    /// Names that carry a reading, an identifier or bytes. A log call naming any of them fails.
    private static let forbidden = [
        "bpm", "percent", "steps", "counter", "runs", "beatsPerMinute", "reading", "battery",
        "peripheral", "identifier", "pairingID", "address", "bytes", "hex", "opcode", "candidate",
        "record", "cursor", "clock", "uuid", "UUID", "localName", "manufacturer",
    ]

    func testTheScrapeFindsTheRingsLogCalls() {
        let calls = Self.ringSources.flatMap { Self.logCalls(in: $0.text) }
        XCTAssertGreaterThanOrEqual(calls.count, 10, "sanity: the scrape must be finding them")
        XCTAssertTrue(calls.allSatisfy { $0.hasPrefix("PrivacyLog.device(.ring,") }, "\(calls)")
    }

    func testNoLogCallCarriesAReadingOrAnIdentifier() {
        for (path, text) in Self.ringSources {
            for call in Self.logCalls(in: text) {
                // Only the arguments after the surface and event: the case names are fixed.
                let arguments = call.drop { $0 != "," }.dropFirst().drop { $0 != "," }
                for word in Self.forbidden {
                    let pattern = "\\b\(word)\\b"
                    XCTAssertNil(arguments.range(of: pattern, options: .regularExpression),
                                 "\(path): \(call) names \(word)")
                }
                XCTAssertFalse(arguments.contains("\\("), "\(path): \(call) interpolates")
            }
        }
    }

    func testNothingInTheFolderLogsAnyOtherWay() {
        for (path, text) in Self.ringSources {
            for banned in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint("] {
                XCTAssertFalse(text.contains(banned), "\(path) uses \(banned)")
            }
        }
    }

    /// The Developer panel's packet log is shown on screen only: it is never saved, logged or put
    /// in a support report.
    func testThePacketLogNeverLeavesTheScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("OpenGlasses/Sources")
        let enumerator = FileManager.default.enumerator(atPath: sources.path)
        var users: [String] = []
        while let path = enumerator?.nextObject() as? String {
            guard path.hasSuffix(".swift") else { continue }
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            if text.contains("packetLog") || text.contains("RingPacketLog") { users.append(path) }
        }
        XCTAssertEqual(Set(users), ["Services/Ring/RingService.swift", "Services/Ring/RingLiveReadings.swift",
                                    "App/Views/RingSettingsView.swift", "App/Views/DeveloperPanelView.swift"])
        let logSource = try String(contentsOf: sources.appendingPathComponent("Services/Ring/RingLiveReadings.swift"),
                                   encoding: .utf8)
        for banned in ["UserDefaults", "FileManager", "write(to", "Codable"] {
            XCTAssertFalse(logSource.contains(banned), banned)
        }
    }
}
