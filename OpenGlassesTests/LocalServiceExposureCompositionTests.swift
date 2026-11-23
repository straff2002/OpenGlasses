import Network
import XCTest
@testable import OpenGlasses

/// W02.1 — containment proved at the composition level rather than only in the pure policy.
///
/// `LocalServiceExposurePolicyTests` shows the policy returns the right decision. These tests
/// compose the real server over an injected policy and a recording listener factory, and assert
/// what a Release build actually does: no listener is ever constructed, the published state is the
/// explicit production-unavailable state, and the persisted developer opt-in is retired. The Debug
/// case asserts the development LAN workflow still reaches listener construction with the expected
/// parameters.
@MainActor
final class LocalServiceExposureCompositionTests: XCTestCase {

    /// Records every listener request and refuses to bind, so no test ever opens a real socket.
    private final class RecordingListenerFactory {
        private(set) var requests: [LocalListenerRequest] = []

        struct RefusedByTest: Error {}

        var factory: LocalListenerFactory {
            { [self] request in
                requests.append(request)
                throw RefusedByTest()
            }
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LocalServiceExposureCompositionTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        Config.hipaaMode = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeObject(forKey: "hipaaMode")
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func seedDeveloperOptIns() {
        defaults.set(true, forKey: "mcpServerEnabled")
    }

    // MARK: - Release

    func testReleaseMCPServerNeverConstructsAListener() {
        seedDeveloperOptIns()
        let recorder = RecordingListenerFactory()
        let server = MCPGlassesServer(policy: LocalServiceExposurePolicy(buildFlavor: .release),
                                      listenerFactory: recorder.factory,
                                      defaults: defaults)

        server.start()
        server.startIfEnabled()

        XCTAssertTrue(recorder.requests.isEmpty,
                      "a Release build must not reach listener construction at all")
        XCTAssertNil(server.listenerBuildMarker)
        XCTAssertEqual(server.availability, .unavailableInProduction)
        XCTAssertFalse(server.isRunning)
        XCTAssertNil(defaults.object(forKey: "mcpServerEnabled"),
                     "refusing must also retire the persisted developer opt-in")
    }

    // MARK: - Debug

    func testDebugMCPServerReachesListenerConstructionOnce() {
        seedDeveloperOptIns()
        let recorder = RecordingListenerFactory()
        let server = MCPGlassesServer(policy: LocalServiceExposurePolicy(buildFlavor: .debug),
                                      listenerFactory: recorder.factory,
                                      defaults: defaults)

        server.start()

        XCTAssertEqual(recorder.requests,
                       [LocalListenerRequest(service: .mcpGlasses, port: 8765,
                                             allowsLocalEndpointReuse: true)])
        XCTAssertNotEqual(server.availability, .unavailableInProduction)
        XCTAssertEqual(defaults.bool(forKey: "mcpServerEnabled"), true,
                       "the development workflow keeps its opt-in")
    }

    // MARK: - Production wiring

    func testProductionFactoryMatchesTheBuildFlavorItShipsIn() throws {
        // The default factory is the one the server gets when nothing is injected. In a Debug
        // build it produces a listener carrying the Debug-only marker; in a Release build it
        // refuses with the marker the artefact check expects to find.
        let request = LocalListenerRequest(service: .mcpGlasses, port: 0)
#if DEBUG
        let handle = try LocalListenerProvider.production(request)
        defer { handle.listener.cancel() }
        XCTAssertEqual(handle.buildMarker,
                       LocalListenerProvider.debugBuildMarker(for: .mcpGlasses))
#else
        XCTAssertThrowsError(try LocalListenerProvider.production(request)) { error in
            XCTAssertEqual(error as? LocalListenerRefusal,
                           LocalListenerRefusal(marker: LocalListenerProvider.releaseRefusalMarker,
                                                service: .mcpGlasses))
        }
#endif
    }

    func testArtefactCheckLiteralsMatchTheOnesTheScriptLooksFor() throws {
        // The script is the headless half of the Release-artefact evidence; keeping its literals
        // in step with the source is what makes a passing script meaningful.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Scripts/check-release-listener-strings.sh"),
                                encoding: .utf8)

        XCTAssertTrue(script.contains(LocalListenerProvider.releaseRefusalMarker))
        XCTAssertTrue(script.contains("mcp-glasses-legacy-cleartext-listener-debug-only"))
        XCTAssertTrue(script.contains("internalSkillPack"))
    }
}
