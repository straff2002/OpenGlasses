import XCTest
import Combine
@testable import OpenGlasses

@MainActor
final class UntrustedNetworkFeaturePolicyTests: XCTestCase {
    private final class InertBackend: GlassesCameraBackend {
        var capabilities: CameraCapabilities = .meta
        let events = PassthroughSubject<CameraBackendEvent, Never>()
        var permissionGranted = false

        func isReady(configuringIfNeeded: Bool) -> Bool { false }
        func ensurePermission() async throws {}
        func capturePhoto() async throws -> Data { Data() }
        func startStreaming() async throws {}
        func stopStreaming() async {}
        func tearDown() async {}
    }

    private final class InertPhone: PhoneCameraCapturing {
        func capturePhoto() async throws -> Data { Data() }
    }

    func testReleaseAllowsEveryFeatureThroughHardenedClient() {
        for feature in UntrustedNetworkFeaturePolicy.Feature.allCases {
            XCTAssertEqual(
                UntrustedNetworkFeaturePolicy.decision(for: feature, build: .release),
                .allowHardenedFetch
            )
        }
    }

    func testDebugAllowsEveryFeatureThroughHardenedClient() {
        for feature in UntrustedNetworkFeaturePolicy.Feature.allCases {
            XCTAssertEqual(
                UntrustedNetworkFeaturePolicy.decision(for: feature, build: .debug),
                .allowHardenedFetch
            )
        }
    }

    func testQRReleaseRefusalHappensBeforeTransport() async throws {
        struct UnexpectedFetch: Error {}
        var fetchCount = 0
        let tool = QRContextTool(
            cameraService: CameraService(
                backend: InertBackend(),
                phoneCamera: InertPhone()
            ),
            networkDecision: .refuseUntilHardenedClient,
            fetch: { _ in
                fetchCount += 1
                throw UnexpectedFetch()
            }
        )

        let result = try await tool.execute(args: ["url": "https://example.test/context.txt"])

        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(result, UntrustedNetworkFeaturePolicy.unavailableMessage)
    }
}
