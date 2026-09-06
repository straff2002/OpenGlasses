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
        suite.set(true, forKey: "hudMirrorEnabled")
        suite.set(true, forKey: "unrelatedPreference")

        LocalServiceExposurePolicy(buildFlavor: .release).clearPersistedOptIns(defaults: suite)

        XCTAssertNil(suite.object(forKey: "mcpServerEnabled"))
        XCTAssertNil(suite.object(forKey: "hudMirrorEnabled"))
        XCTAssertEqual(suite.bool(forKey: "unrelatedPreference"), true)
    }

    func testDebugMigrationKeepsDevelopmentOptIns() throws {
        let suiteName = "LocalServiceExposurePolicyTests-\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: "mcpServerEnabled")
        suite.set(true, forKey: "hudMirrorEnabled")

        LocalServiceExposurePolicy(buildFlavor: .debug).clearPersistedOptIns(defaults: suite)

        XCTAssertEqual(suite.bool(forKey: "mcpServerEnabled"), true)
        XCTAssertEqual(suite.bool(forKey: "hudMirrorEnabled"), true)
    }

    func testBothListenerImplementationsEnforceTheCurrentBuildPolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectations = [
            ("OpenGlasses/Sources/Services/MCPServer/MCPGlassesServer.swift", ".mcpGlasses", false),
            ("OpenGlasses/Sources/Services/Display/WebHUD/WebHUDMirrorServer.swift", ".webHUDMirror", true),
        ]

        for (relativePath, service, protectsRegistrationURL) in expectations {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            let policyCall = "LocalServiceExposurePolicy.current.permitsListener(for: \(service))"
            let start = try XCTUnwrap(source.range(of: "func start()"), "missing start in \(relativePath)")
            let listener = try XCTUnwrap(
                source.range(of: "NWListener(using:", range: start.lowerBound..<source.endIndex),
                "missing listener construction in \(relativePath)"
            )
            let startPrefix = source[start.lowerBound..<listener.lowerBound]
            XCTAssertTrue(
                startPrefix.contains(policyCall),
                "\(relativePath) must refuse through the current-build policy before constructing its listener"
            )
            if protectsRegistrationURL {
                let registration = try XCTUnwrap(source.range(of: "var registrationURL:"))
                XCTAssertTrue(
                    source[registration.lowerBound..<start.lowerBound].contains(policyCall),
                    "\(relativePath) must refuse before constructing its token-bearing registration URL"
                )
            }
        }
    }
}
