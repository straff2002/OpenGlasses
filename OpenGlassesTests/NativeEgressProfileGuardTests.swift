import XCTest
@testable import OpenGlasses

/// Plan LT §2 — every native tool that reaches the network either declares what model-written text
/// it sends (`NativeEgressProfile`) or is exempt here with the reason written down, the same way the
/// frame roster holds every camera consumer.
@MainActor
final class NativeEgressProfileGuardTests: XCTestCase {

    private static var toolsRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/NativeTools")
    }

    /// How a tool reaches the network: our own transports, and MapKit's search, which sends the
    /// query to Apple.
    private static let networkPatterns = ["URLSession", "BoundedHTTPClient", "MKLocalSearch("]

    /// Networked tools that send no model-written text to a third party, by file, and why.
    private static let exemptions: [String: String] = [
        "QRContextTool.swift":
            "Fetches the link printed in a QR code the wearer scanned, to read the venue's page; the "
            + "address is the code's, and nothing the model wrote is added to it.",
        "HomeAssistantTool.swift":
            "Talks only to the wearer's own Home Assistant server, at the address they configured; "
            + "actuation is already confirmed by the high-impact floor.",
        "AircraftOverheadTool.swift":
            "Sends the phone's coarse location and a radius number, never text the model wrote.",
        "OpenClawSkillsTool.swift":
            "Lists and searches skills on the wearer's own gateway, at the address they configured.",
        "CurrencyTool.swift":
            "Sends two three-letter currency codes for published rates, never free text.",
    ]

    private struct Networked { let file: String; let declaresProfile: Bool }

    private func networkedTools() throws -> [Networked] {
        guard let enumerator = FileManager.default.enumerator(at: Self.toolsRoot,
                                                              includingPropertiesForKeys: nil) else {
            XCTFail("Could not enumerate \(Self.toolsRoot.path)")
            return []
        }
        var found: [Networked] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
            guard code.contains(where: { line in Self.networkPatterns.contains { line.contains($0) } })
            else { continue }
            found.append(Networked(file: url.lastPathComponent,
                                   declaresProfile: code.contains { $0.contains("var egressProfile") }))
        }
        return found
    }

    func testEveryNetworkedToolDeclaresAProfileOrAJustifiedExemption() throws {
        let tools = try networkedTools()
        XCTAssertGreaterThanOrEqual(tools.count, 8, "the network scrape found almost nothing — it is vacuous")
        let unaccounted = tools.filter { !$0.declaresProfile && Self.exemptions[$0.file] == nil }
        XCTAssertTrue(unaccounted.isEmpty, """
            These native tools reach the network with no NativeEgressProfile and no exemption. \
            Declare what model-written text they send, or say here why they send none: \
            \(unaccounted.map(\.file).joined(separator: ", "))
            """)
        for (file, reason) in Self.exemptions {
            XCTAssertFalse(reason.isEmpty, file)
        }
    }

    /// An exemption for a file that no longer reaches the network, or that now declares a profile,
    /// is stale and would hide the next tool behind its name.
    func testNoExemptionIsStale() throws {
        let tools = Dictionary(uniqueKeysWithValues: try networkedTools().map { ($0.file, $0) })
        for file in Self.exemptions.keys {
            guard let tool = tools[file] else { return XCTFail("\(file) is exempt but no longer networked") }
            XCTAssertFalse(tool.declaresProfile, "\(file) declares a profile and is exempt as well")
        }
    }

    /// The first set, on the real tools, with keys their own schemas define.
    func testTheFirstSetDeclaresWhatItSends() {
        let tools: [(any NativeTool, NativeEgressProfile)] = [
            (WebSearchTool(), .webSearch),
            (NewsTool(), .news),
            (LocationSearchTool(locationService: LocationService()), .findNearby),
        ]
        for (tool, expected) in tools {
            XCTAssertEqual(tool.egressProfile, expected, tool.name)
            let properties = tool.parametersSchema["properties"] as? [String: Any] ?? [:]
            for key in expected.argumentKeys {
                XCTAssertNotNil(properties[key], "\(tool.name) sends '\(key)', which its schema does not define")
            }
        }
        XCTAssertEqual(NativeEgressProfile.webSearch.route, .webSearch)
        XCTAssertEqual(NativeEgressProfile.news.route, .newsHeadlines)
        XCTAssertNil(NativeEgressProfile.findNearby.route, "MapKit's search is Apple's own request")
        // `translate` sends nothing: the model translates in its reply.
        XCTAssertNil(TranslationTool().egressProfile)
    }

    func testOnlyTheProfiledArgumentsAreOutbound() {
        let args: [String: Any] = ["query": "boiler parts", "recency": "week", "limit": 3]
        XCTAssertEqual(NativeEgressProfile.webSearch.outboundText(from: args), ["boiler parts"])
        let outbound = NativeEgressProfile.webSearch.outboundArguments(from: args)
        XCTAssertEqual(Array(outbound.keys), ["query"])
        XCTAssertEqual(NativeEgressProfile.strings(in: ["a": ["x", ["b": "y"]], "c": 1]), ["x", "y"])
    }
}
