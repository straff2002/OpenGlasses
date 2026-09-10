import Combine
import UIKit
import XCTest
@testable import OpenGlasses

/// W04.1 — the still readers, driven end to end.
///
/// `OutboundFrameConsumerTests` proves every still reader *asks* the chokepoint. That is a claim
/// about the source text. These are the claims about behaviour that go with it, and they are the
/// half that would have caught the original defect from the other side: for each rerouted family,
/// what the model, the log or the Photos library actually receives.
///
/// Two cases per family, and the second matters more than the first:
///
/// 1. **Filtered available** — the sink receives the filtered pixels. A canary colour makes that
///    checkable after a JPEG round trip.
/// 2. **Unavailable** — the sink receives *nothing*. Not the source frame, not an empty image, not
///    a retry with the filter skipped. The failure mode being guarded against is a path that,
///    unable to filter, sends the raw frame anyway; a test that only covers case 1 cannot see it.
@MainActor
final class FilteredStillRoutingTests: XCTestCase {

    // MARK: - Canaries

    /// A two-tone image: `colour` on the left, white on the right.
    ///
    /// Two tones rather than a flat fill because one of the paths under test (navigation assist)
    /// rejects near-uniform frames as unusable, and a flat canary would be dropped for the wrong
    /// reason and pass vacuously.
    private func canary(_ colour: UIColor, size: CGSize = CGSize(width: 32, height: 32)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            UIColor.white.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
    }

    /// What the chokepoint hands back. Blue.
    private var filteredCanary: UIImage { canary(.blue) }

    /// What a raw camera still would look like. Red, and deliberately never given to any provider
    /// in this file: a sink that ever sees red got its pixels somewhere other than the chokepoint.
    private var rawCanary: UIImage { canary(.red) }

    /// Asserts that JPEG bytes decode to the filtered canary rather than a raw frame.
    private func assertFiltered(_ data: Data?, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let data, let image = UIImage(data: data), let cg = image.cgImage else {
            return XCTFail("no decodable image reached the sink. \(message)", file: file, line: line)
        }
        guard let colour = ColorIdentifierTool.averageColor(cg) else {
            return XCTFail("could not sample the delivered image. \(message)", file: file, line: line)
        }
        XCTAssertGreaterThan(colour.b, colour.r + 0.1,
                             "the sink received pixels that are not the filtered canary. \(message)",
                             file: file, line: line)
    }

    // MARK: - Fakes

    /// The chokepoint, faked. Records what each reader asked for, so a test can assert the *scope*
    /// as well as the pixels — a path that requests `.onDeviceVision` for a still it then sends to
    /// a model would deliver filtered-looking bytes and still be wrong.
    private final class FakeStillProvider: FilteredStillProviding {
        var result: FilteredStillResult
        private(set) var requests: [(scope: PrivacyFilterScope, source: FilteredStillSource)] = []

        init(_ result: FilteredStillResult) { self.result = result }

        convenience init(returning image: UIImage, scope: PrivacyFilterScope) {
            self.init(.still(FilteredStill(image: image, scope: scope)))
        }

        func filteredStill(for scope: PrivacyFilterScope,
                           source: FilteredStillSource) async -> FilteredStillResult {
            requests.append((scope, source))
            return result
        }

        var requestedScopes: [PrivacyFilterScope] { requests.map(\.scope) }
    }

    private func availableProvider(scope: PrivacyFilterScope) -> FakeStillProvider {
        FakeStillProvider(returning: filteredCanary, scope: scope)
    }

    private func unavailableProvider() -> FakeStillProvider {
        FakeStillProvider(.unavailable(.filterUnavailable))
    }

    /// The blur, faked, for the one consumer that holds its own pixels.
    private final class FakeStillFilter: StillImageFiltering {
        var replacement: UIImage?
        private(set) var scopes: [PrivacyFilterScope] = []

        init(replacement: UIImage?) { self.replacement = replacement }

        func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage? {
            scopes.append(scope)
            return replacement
        }
    }

    // MARK: - The accessor itself

    /// A camera with no filter wired refuses a filtered scope rather than serving raw pixels. This
    /// is the wiring-omission case, and returning the frame here would reproduce the whole defect
    /// in one line.
    func testAnUnwiredFilterFailsClosedForAFilteredScope() async {
        let (camera, backend) = makeCamera()
        deliver(rawCanary, through: backend)
        camera.privacyFilter = nil

        let result = await camera.filteredStill(for: .visionAssessment)
        XCTAssertEqual(result.unavailableReason, .filterNotWired)
        XCTAssertNil(result.image)
    }

    /// A filter that cannot serve this frame — suspended, locked, Vision failed — is also a refusal.
    func testAnUnavailableFilterFailsClosed() async {
        let (camera, backend) = makeCamera()
        let filter = FakeStillFilter(replacement: nil)
        camera.privacyFilter = filter
        deliver(rawCanary, through: backend)

        let result = await camera.filteredStill(for: .toolPhotoCapture)
        XCTAssertEqual(result.unavailableReason, .filterUnavailable)
        XCTAssertEqual(filter.scopes, [.toolPhotoCapture])
    }

    /// The blur's output is what the caller gets, not the source frame.
    func testAFilteredScopeReturnsTheFiltersOutput() async {
        let (camera, backend) = makeCamera()
        let blue = filteredCanary
        let filter = FakeStillFilter(replacement: blue)
        camera.privacyFilter = filter
        deliver(rawCanary, through: backend)

        let result = await camera.filteredStill(for: .assistiveGuidance)
        assertFiltered(result.jpegData(compressionQuality: 0.8))
    }

    /// An on-device scope is a passthrough — that is what "exempt" means, and the accessor must not
    /// quietly start blurring the frames a Vision pass depends on.
    func testAnOnDeviceScopeIsAPassthrough() async {
        let (camera, backend) = makeCamera()
        let filter = FakeStillFilter(replacement: filteredCanary)
        camera.privacyFilter = filter
        let raw = rawCanary
        deliver(raw, through: backend)

        let result = await camera.filteredStill(for: .onDeviceVision)
        XCTAssertTrue(result.image === raw, "an exempt scope must hand back the source image")
        XCTAssertTrue(filter.scopes.isEmpty, "the blur must not run for an exempt scope")
    }

    /// No frame and no capture is its own answer, distinct from a filter failure — the two lead to
    /// different messages for the wearer ("point at it again" vs "can't right now").
    func testNoStillIsDistinctFromAFilterFailure() async {
        let (camera, _) = makeCamera()
        let filter = FakeStillFilter(replacement: filteredCanary)
        camera.privacyFilter = filter
        let result = await camera.filteredStill(for: .visionAssessment)
        XCTAssertEqual(result.unavailableReason, .noStill)
    }

    /// `.cachedFrameOnly` must never fire the shutter. A background loop asking for "whatever the
    /// stream last gave you" must not become a camera activation the wearer did not ask for.
    func testCachedFrameOnlyNeverCaptures() async {
        let (camera, backend) = makeCamera()
        let filter = FakeStillFilter(replacement: filteredCanary)
        camera.privacyFilter = filter

        _ = await camera.filteredStill(for: .assistiveGuidance, source: .cachedFrameOnly)
        XCTAssertEqual(backend.captureCount, 0)

        _ = await camera.filteredStill(for: .assistiveGuidance, source: .cachedFrameThenPhoto)
        XCTAssertEqual(backend.captureCount, 1, "the fallback should have taken a photo")
    }

    // MARK: - Structured vision

    func testStructuredVisionSendsTheFilteredStill() async throws {
        let service = StructuredVisionService()
        let registry = AssessmentSchemaRegistry()
        registry.register(InstrumentReadingSchema())
        service.registry = registry
        let provider = availableProvider(scope: .visionAssessment)
        service.camera = provider

        var sent: Data?
        service.analyze = { _, _, imageData, _, _ in
            sent = imageData
            return ["readings": [["quantity": "temperature", "value": 212.0,
                                  "unit": "\u{00B0}F", "confidence": 0.9]],
                    "summary": "Reads 212\u{00B0}F.", "confidence": 0.9]
        }

        _ = try? await service.assessCurrentFrame(kind: "instrument_reading", note: nil)
        assertFiltered(sent, "structured vision")
        XCTAssertEqual(provider.requestedScopes, [.visionAssessment])
    }

    func testStructuredVisionSendsNothingWhenTheFilterIsUnavailable() async {
        let service = StructuredVisionService()
        let registry = AssessmentSchemaRegistry()
        registry.register(InstrumentReadingSchema())
        service.registry = registry
        let blocked = unavailableProvider()
        service.camera = blocked
        var called = false
        service.analyze = { _, _, _, _, _ in called = true; return [:] }

        do {
            _ = try await service.assessCurrentFrame(kind: "instrument_reading", note: nil)
            XCTFail("an unfilterable frame must not produce an assessment")
        } catch StructuredVisionError.noFrame {
            // expected: no still, no assessment
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertFalse(called, "the model must not be called with an unfiltered frame")
    }

    // MARK: - Safety assessment

    /// The same shape `SafetyAssessmentServiceTests` uses — a decodable HECA payload.
    private static let safetyFixture: [String: Any] = [
        "summary": "Unshored trench beside a suspended load.",
        "assessments": [
            ["category": "excavation", "is_present": true, "has_direct_control": false,
             "has_indirect_control": true, "indirect_control": "tape"],
        ],
    ]

    func testSafetyAssessmentSendsTheFilteredStill() async {
        let service = SafetyAssessmentService()
        let provider = availableProvider(scope: .visionAssessment)
        service.camera = provider
        service.structuredVision = StructuredVisionService()
        service.store = SafetyAssessmentStore(directory: temporaryDirectory())

        var sent: Data?
        service.analyze = { _, imageData, _, _ in
            sent = imageData
            return Self.safetyFixture
        }

        _ = try? await service.assessCurrentFrame()
        assertFiltered(sent, "safety assessment")
        XCTAssertEqual(provider.requestedScopes, [.visionAssessment])
    }

    func testSafetyAssessmentSendsNothingWhenTheFilterIsUnavailable() async {
        let service = SafetyAssessmentService()
        let blocked = unavailableProvider()
        service.camera = blocked
        service.structuredVision = StructuredVisionService()
        service.store = SafetyAssessmentStore(directory: temporaryDirectory())
        var called = false
        service.analyze = { _, _, _, _ in called = true; return nil }

        _ = try? await service.assessCurrentFrame()
        XCTAssertFalse(called, "a job-site frame that cannot be filtered must not be assessed")
    }

    // MARK: - Guidance loops (assistive, navigation, live coach)

    func testAssistiveModeUsesTheFilteredStill() async {
        let service = AssistiveModeService.shared
        let provider = availableProvider(scope: .assistiveGuidance)
        assertFiltered(await service.currentFrameData(provider), "assistive mode")
        XCTAssertEqual(provider.requestedScopes, [.assistiveGuidance])

        let blocked = unavailableProvider()
        let none = await service.currentFrameData(blocked)
        XCTAssertNil(none, "an unfilterable frame must not reach the guidance model")
    }

    func testNavigationAssistUsesTheFilteredStill() async {
        let service = NavigationAssistService.shared
        let provider = availableProvider(scope: .assistiveGuidance)
        assertFiltered(await service.usableFrameData(provider), "navigation assist")
        XCTAssertEqual(provider.requestedScopes, [.assistiveGuidance])

        let none = await service.usableFrameData(unavailableProvider())
        XCTAssertNil(none)
    }

    func testLiveCoachUsesTheFilteredStill() async {
        let service = LiveCoachService.shared
        let provider = availableProvider(scope: .assistiveGuidance)
        assertFiltered(await service.currentFrame(provider), "live coach")
        XCTAssertEqual(provider.requestedScopes, [.assistiveGuidance])

        let none = await service.currentFrame(unavailableProvider())
        XCTAssertNil(none)
    }

    // MARK: - Page scans (study, teleprompter)

    func testStudyScanReadsTheStillThroughTheChokepoint() async {
        let service = StudyService()
        let provider = availableProvider(scope: .onDeviceVision)
        service.camera = provider
        var ocred: Data?
        service.ocr = { data in ocred = data; return "photosynthesis converts light" }

        _ = await service.scanPage()
        assertFiltered(ocred, "study scan")
        XCTAssertEqual(provider.requestedScopes, [.onDeviceVision],
                       "on-device OCR is exempt, and must say so rather than skipping the accessor")
    }

    func testStudyScanReportsFailureRatherThanScanningAnUnavailableStill() async {
        let service = StudyService()
        let blocked = unavailableProvider()
        service.camera = blocked
        var called = false
        service.ocr = { _ in called = true; return "" }

        let reply = await service.scanPage()
        XCTAssertFalse(called)
        XCTAssertTrue(reply.contains("couldn't capture"), "unexpected reply: \(reply)")
    }

    func testTeleprompterScanReadsTheStillThroughTheChokepoint() async {
        let service = TeleprompterService(store: TeleprompterScriptStore(directory: temporaryDirectory()))
        let provider = availableProvider(scope: .onDeviceVision)
        service.camera = provider
        var ocred: Data?
        service.ocr = { data in ocred = data; return "good evening everyone" }

        _ = await service.scanPage()
        assertFiltered(ocred, "teleprompter scan")
        XCTAssertEqual(provider.requestedScopes, [.onDeviceVision])
    }

    func testTeleprompterScanReportsFailureRatherThanScanningAnUnavailableStill() async {
        let service = TeleprompterService(store: TeleprompterScriptStore(directory: temporaryDirectory()))
        let blocked = unavailableProvider()
        service.camera = blocked
        var called = false
        service.ocr = { _ in called = true; return "" }

        let reply = await service.scanPage()
        XCTAssertFalse(called)
        XCTAssertTrue(reply.contains("couldn't capture"), "unexpected reply: \(reply)")
    }

    // MARK: - Tools

    func testCapturePhotoToolSendsTheFilteredStillToTheModel() async throws {
        let provider = availableProvider(scope: .toolPhotoCapture)
        let tool = CapturePhotoTool(cameraService: provider)

        let result = try await tool.execute(args: [:])
        let payload = try XCTUnwrap(ToolResultImage.extract(from: result).image)
        assertFiltered(payload, "capture_photo")
        XCTAssertEqual(provider.requestedScopes, [.toolPhotoCapture])
    }

    func testCapturePhotoToolReturnsNoImageWhenTheFilterIsUnavailable() async throws {
        let tool = CapturePhotoTool(cameraService: unavailableProvider())
        let result = try await tool.execute(args: [:])
        XCTAssertNil(ToolResultImage.extract(from: result).image, "no image may reach the model")
        XCTAssertTrue(result.contains("Could not capture"), "unexpected reply: \(result)")
    }

    /// An on-device scanning tool takes the same route, and reports honestly when it cannot.
    func testBarcodeScannerAsksTheChokepointAndFailsClosed() async throws {
        let provider = availableProvider(scope: .onDeviceVision)
        let tool = BarcodeScannerTool(cameraService: provider)
        _ = try await tool.execute(args: [:])
        XCTAssertEqual(provider.requestedScopes, [.onDeviceVision])

        let blocked = unavailableProvider()
        let reply = try await BarcodeScannerTool(cameraService: blocked).execute(args: [:])
        XCTAssertTrue(reply.contains("No camera frame"), "unexpected reply: \(reply)")
    }

    // MARK: - Dwell capture

    /// The crop that lands in the Photos library is filtered, while the on-screen preview of the
    /// same capture stays raw — the split the roster records as `dwellCapture` (exempt saliency)
    /// versus `dwellCaptureSave` (filtered egress).
    func testDwellCaptureSavesTheFilteredCropAndPreviewsTheRawOne() async {
        let service = DwellCaptureService()
        let filter = FakeStillFilter(replacement: filteredCanary)
        service.privacyFilter = filter
        // The save is deliberately not awaited in production — the first one can sit on a
        // permission prompt — so the test waits for it rather than assuming it has happened.
        let written = expectation(description: "capture written")
        var saved: UIImage?
        service.saveCapture = { image in
            saved = image
            written.fulfill()
        }

        await fireDwell(on: service, frame: rawCanary)
        await fulfillment(of: [written], timeout: 2)

        XCTAssertEqual(filter.scopes, [.photoLibrary])
        assertFiltered(saved?.jpegData(compressionQuality: 0.9), "dwell capture")
        XCTAssertNotNil(service.lastCapture, "the on-device preview is still shown")
    }

    func testDwellCaptureSavesNothingWhenTheCropCannotBeFiltered() async {
        let service = DwellCaptureService()
        service.privacyFilter = FakeStillFilter(replacement: nil)
        var saved: UIImage?
        service.saveCapture = { saved = $0 }
        var spoken: [String] = []
        service.announce = { spoken.append($0) }

        await fireDwell(on: service, frame: rawCanary)
        await settle()

        XCTAssertNil(saved, "an unfilterable capture must not reach the Photos library")
        XCTAssertFalse(spoken.contains("Captured that."),
                       "the wearer must not be told a capture was saved when it was not")
    }

    /// Nothing is wired at all — the fail-closed default, not a crash and not a raw save.
    func testDwellCaptureSavesNothingWithNoFilterWired() async {
        let service = DwellCaptureService()
        var saved: UIImage?
        service.saveCapture = { saved = $0 }
        await fireDwell(on: service, frame: rawCanary)
        await settle()
        XCTAssertNil(saved)
    }

    // MARK: - Helpers

    /// Drives `DwellTracker` past its dwell threshold with a centred box, then fires.
    private func fireDwell(on service: DwellCaptureService, frame: UIImage) async {
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        await service.advance(boxes: [box], at: 0, frame: frame)
        await service.advance(boxes: [box], at: 3.0, frame: frame)
    }

    /// Lets any detached save task that *would* have run get its turn, so "nothing was saved" is
    /// a real observation rather than a race the test happened to win.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func makeCamera() -> (CameraService, RoutingInertBackend) {
        let backend = RoutingInertBackend()
        return (CameraService(backend: backend, phoneCamera: RoutingInertPhone()), backend)
    }

    /// Puts a frame into `latestFrame` the way the device does — through a backend event. Reaching
    /// in any other way would exercise a path the app never takes.
    private func deliver(_ image: UIImage, through backend: RoutingInertBackend) {
        backend.events.send(.frame(image))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filtered-still-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Inert device doubles

/// A backend that does nothing but let a test hand `CameraService` a frame.
final class RoutingInertBackend: GlassesCameraBackend {
    var capabilities: CameraCapabilities = .meta
    let events = PassthroughSubject<CameraBackendEvent, Never>()
    var permissionGranted = false
    private(set) var captureCount = 0
    /// Not decodable as an image, which keeps the photo-library write out of a unit test.
    var captureResult: Data = Data([0xBE, 0xEF])

    /// Ready, so a capture goes to the "glasses" rather than falling through to the phone —
    /// the branch the still accessor's `capturingIfNeeded` paths are about.
    func isReady(configuringIfNeeded: Bool) -> Bool { true }
    func ensurePermission() async throws {}
    func capturePhoto() async throws -> Data {
        captureCount += 1
        return captureResult
    }
    func startStreaming() async throws {}
    func stopStreaming() async {}
    func tearDown() async {}
}

/// The iPhone fallback, faked — the real one is AVFoundation and hangs a simulator whose camera
/// permission is unresolved.
final class RoutingInertPhone: PhoneCameraCapturing {
    func capturePhoto() async throws -> Data { Data([0xBE, 0xEF]) }
}
