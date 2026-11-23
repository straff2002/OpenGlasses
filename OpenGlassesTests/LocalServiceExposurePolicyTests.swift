import XCTest
@testable import OpenGlasses

final class LocalServiceExposurePolicyTests: XCTestCase {
    func testReleaseRefusesEveryLegacyCleartextListener() {
        let policy = LocalServiceExposurePolicy(buildFlavor: .release)

        for service in LocalServiceExposurePolicy.Service.allCases {
            XCTAssertEqual(policy.decision(for: service), .refuseProductionCleartext)
            XCTAssertFalse(policy.permitsListener(for: service))
        }
    }

    func testDebugPreservesLegacyDevelopmentLANWorkflow() {
        let policy = LocalServiceExposurePolicy(buildFlavor: .debug)

        for service in LocalServiceExposurePolicy.Service.allCases {
            XCTAssertEqual(policy.decision(for: service), .allowLegacyCleartextDevelopmentLAN)
            XCTAssertTrue(policy.permitsListener(for: service))
        }
    }

    func testReleaseMigrationClearsOnlyLegacyListenerOptIns() throws {
        let suiteName = "LocalServiceExposurePolicyTests-\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: "mcpServerEnabled")
        suite.set(true, forKey: "unrelatedPreference")

        LocalServiceExposurePolicy(buildFlavor: .release).clearPersistedOptIns(defaults: suite)

        XCTAssertNil(suite.object(forKey: "mcpServerEnabled"))
        XCTAssertEqual(suite.bool(forKey: "unrelatedPreference"), true)
    }

    func testDebugMigrationKeepsDevelopmentOptIns() throws {
        let suiteName = "LocalServiceExposurePolicyTests-\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: "mcpServerEnabled")

        LocalServiceExposurePolicy(buildFlavor: .debug).clearPersistedOptIns(defaults: suite)

        XCTAssertEqual(suite.bool(forKey: "mcpServerEnabled"), true)
    }

    /// The web mirror of the lens, the other legacy listener, was retired on 2026-11-23.
    func testTheMCPGlassesServerIsTheOnlyLegacyListener() {
        XCTAssertEqual(LocalServiceExposurePolicy.Service.allCases, [.mcpGlasses])
        XCTAssertEqual(LocalServiceExposurePolicy(buildFlavor: .release).persistedOptInKeysToClear,
                       ["mcpServerEnabled"])
    }

    func testTheListenerImplementationEnforcesTheCurrentBuildPolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectations = [
            ("OpenGlasses/Sources/Services/MCPServer/MCPGlassesServer.swift", ".mcpGlasses"),
        ]

        for (relativePath, service) in expectations {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            // The server now holds an injected policy so composition can be tested; the default
            // is still the compile-time one, which is what ships.
            XCTAssertTrue(source.contains("policy: LocalServiceExposurePolicy = .current"),
                          "\(relativePath) must default to the compile-time build policy")
            let policyCall = "policy.permitsListener(for: \(service))"
            let start = try XCTUnwrap(source.range(of: "func start()"), "missing start in \(relativePath)")
            let listener = try XCTUnwrap(
                source.range(of: "listenerFactory(", range: start.lowerBound..<source.endIndex),
                "missing listener construction in \(relativePath)"
            )
            XCTAssertFalse(
                source.contains("NWListener(using:"),
                "\(relativePath) must construct its listener through the injectable factory"
            )
            let startPrefix = source[start.lowerBound..<listener.lowerBound]
            XCTAssertTrue(
                startPrefix.contains(policyCall),
                "\(relativePath) must refuse through the current-build policy before constructing its listener"
            )
        }
    }
}
