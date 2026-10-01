import XCTest
@testable import OpenGlasses

/// Plan GE P0 — every native tool is placed deliberately in or out of the offline set.
@MainActor
final class OfflineToolPolicyTests: XCTestCase {

    /// Tool names scraped from the tools' own `name` declarations, the same way
    /// `FieldToolProfileTests` does: some tools are registered by the app with services a headless
    /// registry does not have, so the sources are the complete list.
    private func declaredToolNames() throws -> Set<String> {
        let toolsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/NativeTools", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: toolsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no tool sources found at \(toolsDirectory.path)")
        // Both spellings: a stored `let name = "x"` and a computed `var name: String { "x" }`.
        let pattern = try NSRegularExpression(
            pattern: #"(?:let|var) name(?:: String)? (?:= |\{ *(?:return )?)"([a-z0-9_]+)""#)
        var declared = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let name = Range(match.range(at: 1), in: source) { declared.insert(String(source[name])) }
            }
        }
        return declared
    }

    func testEveryDeclaredToolIsClassified() throws {
        let declared = try declaredToolNames()
        XCTAssertGreaterThan(declared.count, 100, "the scrape found too few tools to be trusted")
        let missing = declared.filter { OfflineToolPolicy.availability(of: $0) == nil }.sorted()
        XCTAssertEqual(missing, [], "classify each new tool in OfflineToolPolicy.table — local, degraded or needsNetwork")
    }

    func testEveryRegisteredToolIsClassified() {
        let registry = NativeToolRegistry(locationService: LocationService())
        let missing = registry.toolNames.filter { OfflineToolPolicy.availability(of: $0) == nil }.sorted()
        XCTAssertEqual(missing, [])
    }

    func testTheTableNamesOnlyRealTools() throws {
        let declared = try declaredToolNames()
        let stale = OfflineToolPolicy.table.keys.filter { !declared.contains($0) }.sorted()
        XCTAssertEqual(stale, [], "a renamed or removed tool left an entry behind")
    }

    func testNetworkToolsAreNeverOfferedOffline() {
        for name in ["web_search", "get_weather", "find_nearby", "get_directions", "send_via",
                     "openclaw_skills", "code_agent", "home_assistant", "get_news"] {
            XCTAssertFalse(OfflineToolPolicy.isOfferedOffline(name), name)
        }
    }

    func testMCPAndGatewayToolsAreNeverOfferedOffline() {
        // Neither is a native tool; anything unclassified stays out.
        for name in ["mcp__notion__search", "server.tool", "execute", "gateway_execute", "skill_pack_lookup"] {
            XCTAssertNil(OfflineToolPolicy.availability(of: name))
            XCTAssertFalse(OfflineToolPolicy.isOfferedOffline(name), name)
        }
    }

    func testLocalAndDegradedToolsAreOffered() {
        XCTAssertTrue(OfflineToolPolicy.isOfferedOffline("set_timer"))
        XCTAssertTrue(OfflineToolPolicy.isOfferedOffline("save_note"))
        XCTAssertTrue(OfflineToolPolicy.isOfferedOffline("where_am_i"))
        XCTAssertEqual(OfflineToolPolicy.availability(of: "where_am_i"), .degraded)
    }

    func testThePhoneTurnNarrowsTheLocalToolSet() {
        let registered = ["get_weather", "get_datetime", "set_timer", "web_search", "calculate", "save_note"]
        let normal = LLMService.localToolNames(registered: registered, offlineHandoff: false)
        XCTAssertEqual(normal, ["get_weather", "get_datetime", "set_timer", "calculate"],
                       "an ordinary on-device turn keeps the reduced local set it always had")
        let offline = LLMService.localToolNames(registered: registered, offlineHandoff: true)
        XCTAssertEqual(offline, ["get_datetime", "set_timer", "calculate"],
                       "without signal the weather tool would only fail")
    }
}
