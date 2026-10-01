import XCTest
@testable import OpenGlasses

/// Weather comes only from WeatherKit, and every WeatherService request fails in a signed build
/// without `com.apple.developer.weatherkit`. Like HealthKit before it, the key has to agree in
/// three places — the spec, the committed entitlements and the personal example — and an existing
/// personal copy is patched by the setup script.
///
/// The second half keeps the old source out: Open-Meteo's free API is for non-commercial use only,
/// and Avenkin is a paid app, so no part of the app may call or name it again.
final class WeatherKitEntitlementGuardTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent(path))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(object as? [String: Any], "\(path) is not a dictionary plist")
    }

    func testTheSpecDeclaresWeatherKitOnTheAppTarget() throws {
        XCTAssertTrue(try text("project.base.yml").contains("com.apple.developer.weatherkit: true"))
    }

    func testTheCommittedEntitlementsCarryWeatherKit() throws {
        XCTAssertEqual(try plist("OpenGlasses/OpenGlasses.entitlements")["com.apple.developer.weatherkit"] as? Bool, true)
    }

    func testThePersonalEntitlementsExampleCarriesWeatherKit() throws {
        let example = try plist("Config/Entitlements/Personal/OpenGlasses.entitlements.example")
        XCTAssertEqual(example["com.apple.developer.weatherkit"] as? Bool, true)
    }

    func testTheSetupScriptAddsWeatherKitToAnExistingPersonalCopy() throws {
        let script = try text("Scripts/setup-local-dev.sh")
        XCTAssertTrue(script.contains("Add :com.apple.developer.weatherkit bool true"))
        XCTAssertTrue(script.contains("\nensure_personal_capabilities\n"))
        XCTAssertTrue(try text("Scripts/generate-xcodeproj.sh").contains("com.apple.developer.weatherkit"))
    }

    // MARK: - No Open-Meteo

    private static let forbidden = ["open-meteo", "openmeteo", "open_meteo"]

    func testNoAppSourceCallsOrNamesOpenMeteo() throws {
        let root = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in walker where ["swift", "xcprivacy", "plist", "json", "md"].contains(url.pathExtension) {
            guard url.lastPathComponent != "Localizable.xcstrings",
                  let body = (try? String(contentsOf: url, encoding: .utf8))?.lowercased() else { continue }
            if Self.forbidden.contains(where: body.contains) { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "Open-Meteo is not licensed for a paid app")
    }

    func testThePrivacyPageAndManifestNameAppleForWeather() throws {
        let page = try text("privacy.html").lowercased()
        let manifest = try text("OpenGlasses/Sources/Resources/PrivacyInfo.xcprivacy").lowercased()
        for body in [page, manifest] {
            XCTAssertFalse(Self.forbidden.contains(where: body.contains))
        }
        XCTAssertTrue(page.contains("apple weather"))
        XCTAssertTrue(manifest.contains("weatherkit"))
    }

    /// Weather itself is WeatherKit's request, not ours, so it has no route; the mark download is
    /// ours and has one, content-free and blocked under Local Only like every other route.
    func testTheRouteRegistryMatchesWhoOwnsTheTransport() {
        XCTAssertNil(NetworkRoute(rawValue: "weatherLookup"))
        XCTAssertNil(NetworkRouteRegistry.route(owningType: "WeatherTool"))
        let mark = NetworkRoute.weatherAttributionMark
        XCTAssertEqual(mark.dataClasses, [.telemetryFree])
        XCTAssertEqual(mark.owningTypes, ["WeatherAttributionMarkLoader"])
        XCTAssertTrue(mark.medicalPolicy.blocksLocalOnly)
    }
}
