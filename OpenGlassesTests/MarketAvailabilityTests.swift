import XCTest
@testable import OpenGlasses

/// Plan HS P1 item 1 — the storefront gate with a real storefront and a real date: the service that
/// reads the storefront once and answers synchronously, the face recognition tool's refusals, and
/// when the Enrolled Faces screen warns ahead of the date. No StoreKit: the reader and the clock are
/// injected.
@MainActor
final class MarketAvailabilityTests: XCTestCase {

    private struct FakeStorefrontReader: StorefrontReader {
        let code: String?
        func countryCode() async -> String? { code }
    }

    private var annexIIIDay: Date { MarketAvailabilityPolicy.annexIIIApplies }
    private var dayBefore: Date { annexIIIDay.addingTimeInterval(-86_400) }
    private let october2026 = Date(timeIntervalSince1970: 1_791_000_000)
    private var unavailable: MarketAvailabilityPolicy.Availability {
        .unavailableInRegion(reason: MarketAvailabilityPolicy.reason(for: .faceRecognition))
    }

    private func service(_ code: String?, at date: Date) -> MarketAvailability {
        MarketAvailability(reader: FakeStorefrontReader(code: code), now: { date })
    }

    // MARK: - The service

    func testAnEEAStorefrontLosesFaceRecognitionFromTheDay() async {
        let after = service("DE", at: annexIIIDay)
        await after.refresh()
        XCTAssertEqual(after.storefront, "DE")
        XCTAssertEqual(after.availability(of: .faceRecognition), unavailable)
        XCTAssertEqual(after.availability(of: .emotionInference), .available)

        let before = service("DE", at: dayBefore)
        await before.refresh()
        XCTAssertEqual(before.availability(of: .faceRecognition), .available)
    }

    func testANonEEAStorefrontKeepsFaceRecognition() async {
        for code in ["GB", "US", "CH", "NZ"] {
            let market = service(code, at: annexIIIDay)
            await market.refresh()
            XCTAssertEqual(market.availability(of: .faceRecognition), .available, code)
        }
    }

    /// TestFlight sandboxes and signed-out phones report no storefront; a legal gate never fires
    /// on missing data.
    func testANilStorefrontKeepsFaceRecognition() async {
        let market = service(nil, at: annexIIIDay)
        await market.refresh()
        XCTAssertNil(market.storefront)
        XCTAssertEqual(market.availability(of: .faceRecognition), .available)
    }

    /// Before the one read lands the answer is `.available`, whatever the storefront will turn out
    /// to be; the read happens once.
    func testBeforeTheReadCompletesEverythingIsAvailable() async {
        let market = service("FR", at: annexIIIDay)
        XCTAssertNil(market.storefront)
        XCTAssertEqual(market.availability(of: .faceRecognition), .available)
        await market.refresh()
        XCTAssertEqual(market.availability(of: .faceRecognition), unavailable)
        await market.refresh()
        XCTAssertEqual(market.storefront, "FR")
    }

    // MARK: - The advance footer

    func testTheAdvanceFooterShowsOnlyOnAnEEAStorefrontBeforeTheDate() async {
        XCTAssertTrue(MarketAvailability.showsAdvanceNotice(for: .faceRecognition, storefront: "FR", at: october2026))
        XCTAssertTrue(MarketAvailability.showsAdvanceNotice(for: .faceRecognition, storefront: "NO",
                                                            at: annexIIIDay.addingTimeInterval(-1)))
        XCTAssertFalse(MarketAvailability.showsAdvanceNotice(for: .faceRecognition, storefront: "FR", at: annexIIIDay),
                       "from the date the switch carries the reason instead")
        for code in ["GB", "US", "CH", nil] as [String?] {
            XCTAssertFalse(MarketAvailability.showsAdvanceNotice(for: .faceRecognition, storefront: code,
                                                                 at: october2026), code ?? "nil")
        }
        XCTAssertFalse(MarketAvailability.showsAdvanceNotice(for: .emotionInference, storefront: "FR", at: october2026),
                       "an unrestricted capability has nothing to warn about")

        let eea = service("IE", at: october2026)
        XCTAssertFalse(eea.showsFaceRecognitionAdvanceNotice, "not before the storefront is known")
        await eea.refresh()
        XCTAssertTrue(eea.showsFaceRecognitionAdvanceNotice)
        let elsewhere = service("GB", at: october2026)
        await elsewhere.refresh()
        XCTAssertFalse(elsewhere.showsFaceRecognitionAdvanceNotice)
    }

    func testTheAdvanceFooterCopy() {
        let notice = EnrolledFacesPresentation.regionAdvanceNotice
        XCTAssertEqual(notice,
                       "In EU and EEA App Store regions, face recognition will stop being available on 2 December 2027.")
        XCTAssertFalse(notice.contains("Plan"))
    }

    // MARK: - The tool

    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("face-region-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try super.tearDownWithError()
    }

    /// Runs `body` with the face recognition switch on, so the feature gate is not what answers.
    private func withFaceRecognitionOn(_ body: () async throws -> Void) async rethrows {
        let faceSwitch = AIFeature.faceRecognition.record.disableSwitch
        let saved = UserDefaults.standard.object(forKey: faceSwitch.key)
        faceSwitch.setEnabled(true)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: faceSwitch.key) }
            else { UserDefaults.standard.removeObject(forKey: faceSwitch.key) }
        }
        try await body()
    }

    func testTheToolRefusesToEnrolOrStartWhereTheRegionForbidsIt() async throws {
        try await withFaceRecognitionOn {
            let faces = FaceRecognitionService(directory: workspace)
            let camera = CameraService()
            let reason = MarketAvailabilityPolicy.reason(for: .faceRecognition)
            let tool = FaceRecognitionTool(faceService: faces, cameraService: camera,
                                           marketAvailability: { [unavailable] in unavailable })

            for action in ["remember", "on", "toggle"] {
                let answer = try await tool.execute(args: ["action": action, "name": "Maria"])
                XCTAssertEqual(answer, reason, action)
                XCTAssertFalse(faces.isActive, "\(action) started recognition")
            }
            XCTAssertTrue(faces.knownFaces.isEmpty)
            withExtendedLifetime(camera) {}
        }
    }

    /// The wearer can always clear what they enrolled, and switch recognition off.
    func testForgetListAndOffStillWorkWhereTheRegionForbidsIt() async throws {
        try await withFaceRecognitionOn {
            let faces = FaceRecognitionService(directory: workspace)
            let camera = CameraService()
            let reason = MarketAvailabilityPolicy.reason(for: .faceRecognition)
            let tool = FaceRecognitionTool(faceService: faces, cameraService: camera,
                                           marketAvailability: { [unavailable] in unavailable })

            let list = try await tool.execute(args: ["action": "list"])
            XCTAssertNotEqual(list, reason)
            XCTAssertEqual(list, faces.listKnownFaces())
            let forget = try await tool.execute(args: ["action": "forget", "name": "Maria"])
            XCTAssertNotEqual(forget, reason)
            let off = try await tool.execute(args: ["action": "off"])
            XCTAssertEqual(off, "Face recognition disabled.")
            withExtendedLifetime(camera) {}
        }
    }

    func testTheToolIsUnchangedWhereTheRegionAllowsIt() async throws {
        try await withFaceRecognitionOn {
            let faces = FaceRecognitionService(directory: workspace)
            let camera = CameraService()
            let reason = MarketAvailabilityPolicy.reason(for: .faceRecognition)
            let tool = FaceRecognitionTool(faceService: faces, cameraService: camera,
                                           marketAvailability: { .available })

            let remember = try await tool.execute(args: ["action": "remember"])
            XCTAssertEqual(remember, "Please provide a name for the person.", "reached the action itself")
            XCTAssertNotEqual(remember, reason)
            withExtendedLifetime(camera) {}
        }
    }

    /// The tool stays registered where the region forbids it, so the refusal is spoken rather than
    /// the capability vanishing.
    func testTheToolStaysRegistered() {
        let faces = FaceRecognitionService(directory: workspace)
        let camera = CameraService()
        let registry = NativeToolRegistry(locationService: LocationService(),
                                          faceRecognitionService: faces, cameraService: camera)
        XCTAssertNotNil(registry.tool(named: "face_recognition"),
                        "registration does not consult the storefront; the tool refuses instead")
        withExtendedLifetime((faces, camera)) {}
    }
}
