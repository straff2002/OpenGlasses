import UIKit
import XCTest
@testable import OpenGlasses

/// Plan GV P1 — a camera tool with no glasses connected, driven through `CameraService` with a fake
/// backend, a fake headless phone camera, a fake phone-camera sheet and a fake privacy filter.
///
/// The defect these pin: with the glasses away, a tool's still came from a *silent* back-camera
/// shot — a pocket, a bench — with nobody framing it. Every case below that can reach the phone
/// asserts the headless camera was never used.
@MainActor
final class PhoneCameraToolRoutingTests: XCTestCase {

    // MARK: - Fakes

    /// The phone camera sheet, faked: hands back queued outcomes and records what was asked.
    @MainActor
    final class FakePhonePhotos: PhonePhotoRequesting {
        var outcomes: [PhonePhotoOutcome]
        private(set) var requests: [PhonePhotoRequest] = []

        init(_ outcomes: [PhonePhotoOutcome]) { self.outcomes = outcomes }

        func requestPhoto(_ request: PhonePhotoRequest) async -> PhonePhotoOutcome {
            requests.append(request)
            return outcomes.isEmpty ? .cancelled : outcomes.removeFirst()
        }
    }

    /// The blur pass, faked: returns a blue canary, or refuses.
    @MainActor
    final class FakeFilter: StillImageFiltering {
        var available = true
        private(set) var scopes: [PrivacyFilterScope] = []
        func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage? {
            scopes.append(scope)
            guard available else { return nil }
            return PhoneCameraToolRoutingTests.canary(.blue)
        }
    }

    nonisolated static func canary(_ colour: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 32, height: 32)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
            UIColor.white.setFill()
            context.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        }
    }

    /// A photo as the phone sheet would hand it over: real JPEG bytes, red.
    private var phonePhotoBytes: Data { Self.canary(.red).jpegData(compressionQuality: 0.9)! }

    private struct Rig {
        let service: CameraService
        let backend: MockCameraBackend
        let headless: MockPhoneCamera
        let sheet: FakePhonePhotos
        let filter: FakeFilter
        var savedToLibrary: Int { savedBox.count }
        let savedBox: Counter
    }

    final class Counter { var count = 0 }

    private func rig(glassesLinkUp: Bool = false,
                     outcomes: [PhonePhotoOutcome] = []) -> Rig {
        let backend = MockCameraBackend(isReady: true)
        backend.captureResult = .success(Data([0xDE, 0xAD]))
        let headless = MockPhoneCamera()
        let service = CameraService(backend: backend, phoneCamera: headless)
        service.isGlassesLinkUp = { glassesLinkUp }
        let sheet = FakePhonePhotos(outcomes)
        service.phonePhotos = sheet
        let filter = FakeFilter()
        service.privacyFilter = filter
        let saved = Counter()
        service.captureLibrarySink = { _ in saved.count += 1 }
        return Rig(service: service, backend: backend, headless: headless, sheet: sheet,
                   filter: filter, savedBox: saved)
    }

    /// Runs `work` as if the named tool were executing, with a fresh ledger, as the router does.
    private func asTool<T>(_ name: String, ledger: PhoneCaptureLedger = PhoneCaptureLedger(),
                           _ work: () async throws -> T) async rethrows -> T {
        try await ToolInvocationScope.$current.withValue(.root(name: name, origin: .model)) {
            try await PhoneCaptureScope.$ledger.withValue(ledger) { try await work() }
        }
    }

    // MARK: - Routing

    func testAToolWithNoGlassesOpensThePhoneCameraAndNeverTakesAHiddenShot() async throws {
        let rig = rig(outcomes: [.photo(Data([0xAB]))])
        let ledger = PhoneCaptureLedger()

        let data = try await asTool("safety_assessment", ledger: ledger) {
            try await rig.service.capturePhoto()
        }

        XCTAssertEqual(data, Data([0xAB]))
        XCTAssertEqual(rig.headless.captureCount, 0, "never the silent back camera")
        XCTAssertEqual(rig.backend.captureCount, 0)
        XCTAssertEqual(rig.sheet.requests.map(\.toolName), ["safety_assessment"])
        XCTAssertEqual(rig.sheet.requests.first?.hint,
                       PhoneCapturePolicy.framingHint(forTool: "safety_assessment"))
        XCTAssertEqual(rig.service.lastCaptureSource, .phone)
        XCTAssertEqual(ledger.phonePhotos, 1)
        XCTAssertEqual(rig.savedToLibrary, 1, "filed like every other capture")
    }

    func testWithGlassesConnectedNothingChanges() async throws {
        let rig = rig(glassesLinkUp: true)
        _ = try await asTool("equipment_lookup") { try await rig.service.capturePhoto() }
        XCTAssertEqual(rig.backend.captureCount, 1)
        XCTAssertTrue(rig.sheet.requests.isEmpty)
        XCTAssertEqual(rig.headless.captureCount, 0)
        XCTAssertEqual(rig.service.lastCaptureSource, .glasses)
    }

    func testAGlassesOnlyToolRefusesWithoutGlasses() async {
        let rig = rig()
        do {
            _ = try await asTool("face_recognition") { try await rig.service.capturePhoto() }
            XCTFail("a glasses-only tool must not get a phone picture")
        } catch {
            XCTAssertTrue(error is CameraService.GlassesOnlyCaptureError)
        }
        XCTAssertTrue(rig.sheet.requests.isEmpty)
        XCTAssertEqual(rig.headless.captureCount, 0)
    }

    func testNoToolInScopeKeepsTheExistingHeadlessFallback() async throws {
        // The app's own photo paths (which announce the swap) are out of this plan's scope.
        let rig = rig()
        let data = try await rig.service.capturePhoto()
        XCTAssertEqual(data, Data([0xBE, 0xEF]))
        XCTAssertEqual(rig.headless.captureCount, 1)
        XCTAssertTrue(rig.sheet.requests.isEmpty)
    }

    func testATempleTapStaysGlassesOnlyEvenInsideATool() async {
        let rig = rig()
        do {
            _ = try await asTool("capture_photo") {
                try await rig.service.capturePhoto(allowPhoneFallback: false)
            }
            XCTFail("allowPhoneFallback: false is glasses or nothing")
        } catch {
            XCTAssertTrue(error is CameraService.GlassesOnlyCaptureError)
        }
        XCTAssertTrue(rig.sheet.requests.isEmpty)
    }

    func testNoSheetWiredRefusesRatherThanShootingThePocket() async {
        let rig = rig()
        rig.service.phonePhotos = nil
        let ledger = PhoneCaptureLedger()
        do {
            _ = try await asTool("photo_log", ledger: ledger) { try await rig.service.capturePhoto() }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? PhonePhotoError, PhonePhotoError(outcome: .couldNotPresent))
        }
        XCTAssertEqual(rig.headless.captureCount, 0)
        XCTAssertEqual(ledger.failure, .couldNotPresent)
    }

    // MARK: - Cancel / timeout

    func testACancelIsRecordedAndNotAskedTwiceInTheSameCall() async {
        let rig = rig(outcomes: [.cancelled, .photo(Data([1]))])
        let ledger = PhoneCaptureLedger()

        // `reading_assist` / `capture_photo` shape: a stream-frame read, then a shutter photo.
        let first = await asTool("reading_assist", ledger: ledger) {
            await rig.service.filteredStill(for: .onDeviceVision)
        }
        let second = await asTool("reading_assist", ledger: ledger) {
            await rig.service.filteredStill(for: .onDeviceVision, source: .photoOnly)
        }

        XCTAssertNil(first.still)
        XCTAssertNil(second.still)
        XCTAssertEqual(rig.sheet.requests.count, 1, "the camera opened once, not twice")
        XCTAssertEqual(ledger.failure, .cancelled)
        XCTAssertEqual(rig.headless.captureCount, 0)
        XCTAssertEqual(rig.savedToLibrary, 0)
    }

    func testATimeoutThrowsItsSentence() async {
        let rig = rig(outcomes: [.timedOut])
        do {
            _ = try await asTool("scan_document") { try await rig.service.capturePhoto() }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, PhonePhotoOutcome.timedOut.toolResultSentence)
        }
    }

    // MARK: - Stream-only readers

    func testAStreamFrameRequestFromAnAskOnPhoneToolBecomesAPhoto() async {
        let rig = rig(outcomes: [.photo(phonePhotoBytes)])
        let result = await asTool("scan_code") {
            await rig.service.filteredStill(for: .onDeviceVision)
        }
        XCTAssertNotNil(result.still, "scan_code gets the phone photo instead of 'no frame'")
        XCTAssertEqual(rig.sheet.requests.count, 1)
    }

    func testAStreamFrameRequestStaysStreamOnlyWithGlassesOrForGlassesOnlyTools() async {
        let withGlasses = rig(glassesLinkUp: true)
        let a = await asTool("scan_code") { await withGlasses.service.filteredStill(for: .onDeviceVision) }
        XCTAssertNil(a.still)
        XCTAssertEqual(withGlasses.backend.captureCount, 0, "unchanged: no frame, no capture")

        let glassesOnly = rig()
        let b = await asTool("face_recognition") {
            await glassesOnly.service.filteredStill(for: .faceRecognition)
        }
        XCTAssertNil(b.still)
        XCTAssertTrue(glassesOnly.sheet.requests.isEmpty)
    }

    // MARK: - Privacy filter

    func testAPhonePhotoIsFilteredUnderTheToolsScope() async throws {
        let rig = rig(outcomes: [.photo(phonePhotoBytes)])
        let result = await asTool("capture_photo") {
            await rig.service.filteredStill(for: .toolPhotoCapture, source: .photoOnly)
        }
        let image = try XCTUnwrap(result.image)
        XCTAssertEqual(rig.filter.scopes, [.toolPhotoCapture])
        let colour = try XCTUnwrap(image.cgImage.flatMap(ColorIdentifierTool.averageColor))
        XCTAssertGreaterThan(colour.b, colour.r + 0.1, "the filtered pixels, not the phone's")
    }

    func testAPhonePhotoIsWithheldWhenTheFilterCannotRun() async {
        let rig = rig(outcomes: [.photo(phonePhotoBytes)])
        rig.filter.available = false
        let result = await asTool("vision_assess") {
            await rig.service.filteredStill(for: .visionAssessment, source: .cachedFrameThenPhoto)
        }
        XCTAssertNil(result.still)
        XCTAssertEqual(result.unavailableReason, .filterUnavailable)
        XCTAssertNil(result.jpegData(compressionQuality: 0.8), "never the raw phone pixels")
    }

    // MARK: - Router

    private struct CameraStub: NativeTool {
        let name = "camera_stub_tool"
        let description = "test stub"
        let camera: CameraService
        var parametersSchema: [String: Any] { ["type": "object"] }
        var executionSemantics: ToolExecutionSemantics { .read() }
        func execute(args: [String: Any]) async throws -> String {
            let still = await camera.filteredStill(for: .onDeviceVision, source: .photoOnly)
            return still.still == nil ? "Could not capture an image." : "Read: FAULT E4"
        }
    }

    func testTheRouterPrependsTheSentenceWhenThePhotoWasCancelled() async {
        let rig = rig(outcomes: [.cancelled])
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(CameraStub(camera: rig.service))
        let router = NativeToolRouter(registry: registry)
        router.glassesCameraConnected = { false }

        let outcome = await router.executeRoot(name: "camera_stub_tool", args: [:])
        guard case .completed(let text) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(text.hasPrefix(PhonePhotoOutcome.cancelled.toolResultSentence!), text)
        XCTAssertTrue(text.hasSuffix("Could not capture an image."), text)
    }

    func testTheRouterNotesAPhonePhoto() async {
        let rig = rig(outcomes: [.photo(phonePhotoBytes)])
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(CameraStub(camera: rig.service))
        let router = NativeToolRouter(registry: registry)
        router.glassesCameraConnected = { false }

        let outcome = await router.executeRoot(name: "camera_stub_tool", args: [:])
        guard case .completed(let text) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(text, "Read: FAULT E4\n" + PhoneCapturePolicy.phonePhotoNote)
        XCTAssertEqual(rig.sheet.requests.map(\.toolName), ["camera_stub_tool"])
    }
}
