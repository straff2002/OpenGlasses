import CoreLocation
import UIKit
import XCTest
@testable import OpenGlasses

/// Plan GH P2 — the sign photo passes the privacy chokepoint before OCR reads it or the store keeps
/// it, and fails closed when the chokepoint cannot run.
@MainActor
final class ParkingPhotoFlowTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeStillProvider: FilteredStillProviding {
        var results: [FilteredStillSource: FilteredStillResult] = [:]
        private(set) var requests: [(scope: PrivacyFilterScope, source: FilteredStillSource)] = []

        func filteredStill(for scope: PrivacyFilterScope,
                           source: FilteredStillSource) async -> FilteredStillResult {
            requests.append((scope, source))
            return results[source] ?? .unavailable(.noStill)
        }
    }

    private final class FakeFilter: StillImageFiltering {
        var output: UIImage?
        private(set) var scopes: [PrivacyFilterScope] = []
        init(output: UIImage?) { self.output = output }
        func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage? {
            scopes.append(scope)
            return output
        }
    }

    private func image(_ colour: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private var directory: URL!
    private var ocrCalls = 0

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParkingPhotoFlowTests_\(UUID().uuidString)", isDirectory: true)
        ocrCalls = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func flow(camera: FakeStillProvider? = nil, filter: FakeFilter? = nil,
                      lines: @escaping (Int) -> [String]) -> ParkingPhotoFlow {
        ParkingPhotoFlow(seams: .init(
            camera: { camera },
            filter: { filter },
            recognize: { [unowned self] _ in
                self.ocrCalls += 1
                return lines(self.ocrCalls)
            }))
    }

    private func still(_ scope: PrivacyFilterScope = .toolPhotoCapture) -> FilteredStillResult {
        .still(FilteredStill(image: image(.blue), scope: scope))
    }

    // MARK: - Glasses

    func testTheGlassesStillIsRequestedForTheToolPhotoScopeAndRead() async {
        let camera = FakeStillProvider()
        camera.results[.cachedFrameOnly] = still()
        let outcome = await flow(camera: camera, lines: { _ in ["LEVEL 2", "BAY 41"] }).captureFromGlasses()
        guard case .read(let reading, let jpeg) = outcome else { return XCTFail("expected a reading") }
        XCTAssertEqual(reading.fields, ParkingFields(level: "2", space: "41"))
        XCTAssertFalse(jpeg.isEmpty)
        XCTAssertEqual(camera.requests.map(\.scope), [.toolPhotoCapture])
    }

    func testAnUnreadableCachedFrameFallsBackToAFreshPhoto() async {
        let camera = FakeStillProvider()
        camera.results[.cachedFrameOnly] = still()
        camera.results[.photoOnly] = still()
        let outcome = await flow(camera: camera, lines: { call in call == 1 ? [] : ["P3"] }).captureFromGlasses()
        guard case .read(let reading, _) = outcome else { return XCTFail("expected a reading") }
        XCTAssertEqual(reading.fields.level, "3")
        XCTAssertEqual(camera.requests.map(\.source), [.cachedFrameOnly, .photoOnly])
        XCTAssertEqual(Set(camera.requests.map(\.scope)), [.toolPhotoCapture])
    }

    func testAClosedPrivacyGateIsNotRetriedAndNothingIsRead() async {
        let camera = FakeStillProvider()
        camera.results[.cachedFrameOnly] = .unavailable(.filterUnavailable)
        camera.results[.photoOnly] = still()
        let outcome = await flow(camera: camera, lines: { _ in ["LEVEL 2"] }).captureFromGlasses()
        guard case .unavailable(.filterUnavailable) = outcome else { return XCTFail("must fail closed") }
        XCTAssertEqual(camera.requests.count, 1, "retrying past a closed privacy gate is what the gate stops")
        XCTAssertEqual(ocrCalls, 0)
    }

    // MARK: - Phone

    func testAPhonePhotoIsFilteredBeforeOCR() async {
        let filter = FakeFilter(output: image(.green))
        let outcome = await flow(filter: filter, lines: { _ in ["LEVEL 4"] }).acceptPhonePhoto(image(.red))
        guard case .read(let reading, _) = outcome else { return XCTFail("expected a reading") }
        XCTAssertEqual(reading.fields.level, "4")
        XCTAssertEqual(filter.scopes, [.toolPhotoCapture])
    }

    func testAPhonePhotoWithNoFilterWiredFailsClosed() async {
        let outcome = await flow(lines: { _ in ["LEVEL 4"] }).acceptPhonePhoto(image(.red))
        guard case .unavailable(.filterUnavailable) = outcome else { return XCTFail("must fail closed") }
        XCTAssertEqual(ocrCalls, 0)
    }

    func testAPhonePhotoTheFilterRefusesIsNotRead() async {
        let filter = FakeFilter(output: nil)
        let outcome = await flow(filter: filter, lines: { _ in ["LEVEL 4"] }).acceptPhonePhoto(image(.red))
        guard case .unavailable(.filterUnavailable) = outcome else { return XCTFail("must fail closed") }
        XCTAssertEqual(ocrCalls, 0)
    }

    // MARK: - Filing

    func testFilingWithNoActiveSpotCreatesAPhotoSpot() {
        let store = ParkingStore(directory: directory, keepHistory: { false })
        let reading = ParkingSignParser.parse(lines: ["B12"])
        let message = ParkingPhotoFlow.file(.read(reading, jpeg: Data([1, 2, 3])), into: store,
                                            location: LocationFix(latitude: 1, longitude: 2, at: Date()),
                                            now: Date())
        XCTAssertEqual(store.active?.capture, .photo)
        XCTAssertEqual(store.active?.space, "B12")
        XCTAssertNotNil(store.active?.photoFile)
        XCTAssertTrue(message.contains("check that's right"), message)
    }

    func testFilingARefusedPhotoKeepsNothing() {
        let store = ParkingStore(directory: directory, keepHistory: { false })
        let message = ParkingPhotoFlow.file(.unavailable(.filterUnavailable), into: store, location: nil, now: Date())
        XCTAssertNil(store.active)
        XCTAssertTrue(message.contains("wasn't kept"), message)
    }

    func testThePhotoActionSavesTheSpotWithThePhotoAndAsksWhenUnsure() async throws {
        let camera = FakeStillProvider()
        camera.results[.cachedFrameOnly] = still()
        let store = ParkingStore(directory: directory, keepHistory: { false })
        let tool = ParkingTool(seams: .init(
            store: { store },
            currentLocation: { nil },
            photoFlow: { [unowned self] in self.flow(camera: camera, lines: { _ in ["L2", "041"] }) }))
        let reply = try await tool.execute(args: ["action": "photo"])
        XCTAssertEqual(store.active?.capture, .photo)
        XCTAssertEqual(store.active?.level, "2")
        XCTAssertEqual(store.active?.space, "41")
        XCTAssertNotNil(store.active?.photoFile)
        XCTAssertTrue(reply.contains("is that right?"), reply)
    }
}
