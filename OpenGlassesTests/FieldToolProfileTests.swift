import XCTest
@testable import OpenGlasses

/// Plan GD3 — during a Field Assist job, only field tools are offered to the model, and the
/// prompt's tool list and the declared schemas say the same thing.
final class FieldToolProfileTests: XCTestCase {

    private let all = ["web_search", "smart_home", "field_session", "spotify", "capture_photo",
                       "manual_lookup", "get_weather"]

    // MARK: - The pure rule

    func testWithNoJobEveryToolIsOffered() {
        XCTAssertEqual(FieldToolProfile.declaredNames(all: all, fieldJobActive: false, enabled: true), all)
    }

    func testAJobWithTheProfileOnOffersTheSortedIntersection() {
        XCTAssertEqual(FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: true),
                       ["capture_photo", "field_session", "get_weather", "manual_lookup", "web_search"])
    }

    func testAJobWithTheProfileOffOffersEveryTool() {
        XCTAssertEqual(FieldToolProfile.declaredNames(all: all, fieldJobActive: true, enabled: false), all)
    }

    func testHIPAADisabledToolsStayOutWithTheProfileOn() {
        let declared = ToolDeclarations.declarableNames(all, isEnabled: { _ in true }, hipaaMode: true,
                                                        hipaaDisabled: ["capture_photo"],
                                                        fieldJobActive: true, fieldProfileEnabled: true)
        XCTAssertEqual(declared, ["field_session", "get_weather", "manual_lookup", "web_search"])
        // …and a disabled tool stays out whatever the profile says.
        let disabled = ToolDeclarations.declarableNames(all, isEnabled: { $0 != "web_search" }, hipaaMode: false,
                                                        hipaaDisabled: [], fieldJobActive: true,
                                                        fieldProfileEnabled: true)
        XCTAssertFalse(disabled.contains("web_search"))
    }

    func testTheDeclarableDefaultsLeaveTheListAsItWas() {
        XCTAssertEqual(ToolDeclarations.declarableNames(all, isEnabled: { _ in true }, hipaaMode: false,
                                                        hipaaDisabled: []), all.sorted())
    }

    func testTheDigestIsStableAndOrderFree() {
        let digest = FieldToolProfile.digest(["b", "a"])
        XCTAssertEqual(digest, FieldToolProfile.digest(["a", "b"]))
        XCTAssertEqual(digest.count, 12)
        XCTAssertNotEqual(digest, FieldToolProfile.digest(["a"]))
        XCTAssertEqual(PrivacyToken(digest).description, digest, "the digest is a loggable token")
    }

    func testTheProfileIsOnByDefault() {
        let previous = UserDefaults.standard.object(forKey: "fieldToolProfileEnabled")
        defer { UserDefaults.standard.set(previous, forKey: "fieldToolProfileEnabled") }
        UserDefaults.standard.removeObject(forKey: "fieldToolProfileEnabled")
        XCTAssertTrue(Config.fieldToolProfileEnabled)
        Config.fieldToolProfileEnabled = false
        XCTAssertFalse(Config.fieldToolProfileEnabled)
    }

    // MARK: - Against the real registry

    /// Every profile name is a native tool. Scraped from the tools' own `name` declarations rather
    /// than read off a registry: the Field Assist tools are registered by the app with services a
    /// headless registry does not have, so a registry built here holds only some of them.
    func testEveryProfileNameIsANativeTool() throws {
        let toolsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/NativeTools", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: toolsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no tool sources found at \(toolsDirectory.path)")
        let pattern = try NSRegularExpression(pattern: #"(?:let|var) name(?:: String)? = "([a-z0-9_]+)""#)
        var declared = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                if let name = Range(match.range(at: 1), in: source) { declared.insert(String(source[name])) }
            }
        }
        let missing = FieldToolProfile.names.subtracting(declared).sorted()
        XCTAssertEqual(missing, [], "profile names with no tool behind them")
    }

    /// A request with the profile on lists exactly the names it declares — so a tool is either
    /// declared and listed or neither — and it is a real narrowing.
    @MainActor
    func testThePromptListAndTheDeclaredSchemasAgree() {
        let registry = NativeToolRegistry(locationService: LocationService())
        let listed = FieldToolProfile.declaredNames(all: registry.toolNames, fieldJobActive: true, enabled: true)
        let declared = ToolDeclarations.nativeToolDeclarations(registry: registry, fieldJobActive: true,
                                                               fieldProfileEnabled: true)
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(declared, listed)
        XCTAssertLessThan(declared.count, registry.toolNames.count)
        XCTAssertTrue(Set(declared).isSubset(of: FieldToolProfile.names))

        // Off, or with no job, both lists are the whole registry's.
        let everything = ToolDeclarations.nativeToolDeclarations(registry: registry, fieldJobActive: false,
                                                                 fieldProfileEnabled: true)
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(everything, registry.toolNames)
    }
}
