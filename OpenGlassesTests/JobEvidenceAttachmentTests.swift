import XCTest
@testable import OpenGlasses

/// Every route a photograph can reach a job by, and what each one stores (Plan FO P2a).
///
/// The claim under test is the one Plan FO P0 corrected the draft on: **filtering is not
/// inherited.** `photo_log` went through the chokepoint from the start; a plain capture and a
/// phone-sourced picture did not, and attaching them to a job without each asking for a filtered
/// copy in its own right would put unblurred bystanders into a document a customer reads.
///
/// So the canary here is the same one `FilteredStillRoutingTests` uses: red pixels are what a raw
/// still looks like and are never handed to anything that is supposed to filter; blue is what the
/// chokepoint returns. A stored file that samples red got its bytes somewhere it should not have.
@MainActor
final class JobEvidenceAttachmentTests: XCTestCase {

    private var sessionsRoot: URL!
    private var service: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousFilterSetting: Any?

    override func setUp() {
        super.setUp()
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("JobEvidence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousFilterSetting = UserDefaults.standard.object(forKey: "privacyFilterEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        service = FieldSessionService(sessionsRoot: sessionsRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sessionsRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        if let previousFilterSetting {
            UserDefaults.standard.set(previousFilterSetting, forKey: "privacyFilterEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "privacyFilterEnabled")
        }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Canaries and fakes

    private func canary(_ colour: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image {
            context in
            colour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
            UIColor.white.setFill()
            context.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        }
    }

    private var filteredCanary: UIImage { canary(.blue) }
    private var rawCanary: UIImage { canary(.red) }

    /// The chokepoint, faked. Hands back whatever it was built with, and records the scope asked
    /// for — a route that requested the wrong scope would deliver filtered-looking bytes and still
    /// be wrong.
    private final class FakeStillProvider: FilteredStillProviding {
        var result: FilteredStillResult
        private(set) var requests: [(scope: PrivacyFilterScope, source: FilteredStillSource)] = []

        init(_ result: FilteredStillResult) { self.result = result }

        func filteredStill(for scope: PrivacyFilterScope,
                           source: FilteredStillSource) async -> FilteredStillResult {
            requests.append((scope, source))
            return result
        }
    }

    /// The blur, faked, for the consumer that holds its own pixels. `replacement` nil is the
    /// "must filter and cannot" answer.
    private final class FakeStillFilter: StillImageFiltering {
        let replacement: UIImage?
        /// Passthrough — what the real filter does when the setting is off.
        let passthrough: Bool
        private(set) var scopes: [PrivacyFilterScope] = []

        init(replacement: UIImage?, passthrough: Bool = false) {
            self.replacement = replacement
            self.passthrough = passthrough
        }

        func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage? {
            scopes.append(scope)
            return passthrough ? image : replacement
        }
    }

    private func evidenceService(filter: FakeStillFilter?, filterOn: Bool) -> JobPhotoEvidenceService {
        JobPhotoEvidenceService(seams: .init(sessions: { [service] in service! },
                                             filter: { filter },
                                             filterEnabled: { filterOn }))
    }

    // MARK: - Assertions

    /// Sample what actually landed on disk, not what the caller thought it handed over.
    private func storedColour(_ itemId: String, file: StaticString = #filePath,
                              line: UInt = #line) -> (r: Double, g: Double, b: Double)? {
        guard let session = service.activeSession ?? service.history.first else {
            XCTFail("no session to read evidence from", file: file, line: line)
            return nil
        }
        let url = service.photosDirectory(sessionId: session.id).appendingPathComponent(itemId)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data),
              let cg = image.cgImage, let colour = ColorIdentifierTool.averageColor(cg) else {
            XCTFail("no decodable image stored at \(itemId)", file: file, line: line)
            return nil
        }
        return (colour.r, colour.g, colour.b)
    }

    private func assertStoredIsFiltered(_ itemId: String, _ message: String = "",
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let colour = storedColour(itemId, file: file, line: line) else { return }
        XCTAssertGreaterThan(colour.b, colour.r + 0.1,
                             "stored bytes did not come through the filter. \(message)",
                             file: file, line: line)
    }

    private func startJob(reference: String = "1005") throws -> FieldSession {
        try service.startSession(vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                 jobReference: reference)
    }

    private func jpeg(_ image: UIImage) throws -> Data {
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    // MARK: - photo_log

    func testPhotoLogFilesTheFilteredStillWithItsOriginAndBlurState() async throws {
        _ = try startJob()
        Config.setPrivacyFilterEnabled(true)
        let provider = FakeStillProvider(.still(FilteredStill(image: filteredCanary,
                                                              scope: .toolPhotoCapture)))
        let tool = PhotoLogTool(cameraService: provider, jobEvidence: service)

        _ = try await tool.execute(args: ["caption": "suction gauge 118 PSIG"])

        let media = try XCTUnwrap(service.jobMedia.first)
        XCTAssertEqual(service.jobMedia.count, 1)
        XCTAssertEqual(media.origin, .photoLog)
        XCTAssertEqual(media.caption, "suction gauge 118 PSIG")
        XCTAssertTrue(media.filterWasOn)
        XCTAssertEqual(provider.requests.map(\.scope), [.toolPhotoCapture])
        assertStoredIsFiltered(media.id, "photo_log")
    }

    func testPhotoLogAttachesNothingWithNoJobOpen() async throws {
        let provider = FakeStillProvider(.still(FilteredStill(image: filteredCanary,
                                                              scope: .toolPhotoCapture)))
        let reply = try await PhotoLogTool(cameraService: provider, jobEvidence: service)
            .execute(args: [:])
        XCTAssertTrue(reply.contains("No active Field Assist session"), "unexpected reply: \(reply)")
        XCTAssertTrue(service.jobMedia.isEmpty)
    }

    // MARK: - capture_photo

    /// A plain capture during a visit is evidence of that visit — and it is *offered*, not
    /// assumed, which is what the selection default says.
    func testAPlainCaptureLandsOnTheOpenJobAndIsOfferedNotAssumed() async throws {
        _ = try startJob()
        Config.setPrivacyFilterEnabled(false)
        let provider = FakeStillProvider(.still(FilteredStill(image: filteredCanary,
                                                              scope: .toolPhotoCapture)))
        let tool = CapturePhotoTool(cameraService: provider, jobEvidence: service)

        _ = try await tool.execute(args: ["reason": "look at this coil"])

        let media = try XCTUnwrap(service.jobMedia.first)
        XCTAssertEqual(media.origin, .capture)
        XCTAssertEqual(media.caption, "look at this coil")
        XCTAssertFalse(media.filterWasOn)
        assertStoredIsFiltered(media.id, "capture_photo cached frame")
        XCTAssertFalse(service.evidenceSelection().entry(for: media.id)!.included,
                       "a plain capture is offered at review, not pre-selected")
    }

    /// The shutter image too. `capturePhoto()` is exempt for the wearer's own framed shot; a still
    /// that becomes job evidence is not that, and asks the accessor with `source: .photoOnly`.
    func testTheShutterImageIsFilteredBeforeItBecomesEvidence() async throws {
        _ = try startJob()
        // Nothing cached, so the tool falls through to the shutter — and the shutter request goes
        // to the accessor with `.photoOnly` rather than to the unfiltered `capturePhoto()`.
        let shutterProvider = SequencedProvider(results: [
            .unavailable(.noStill),
            .still(FilteredStill(image: filteredCanary, scope: .toolPhotoCapture)),
        ])
        _ = try await CapturePhotoTool(cameraService: shutterProvider,
                                       jobEvidence: service).execute(args: [:])

        let media = try XCTUnwrap(service.jobMedia.first)
        XCTAssertEqual(shutterProvider.requests.map(\.source), [.cachedFrameOnly, .photoOnly])
        XCTAssertEqual(shutterProvider.requests.map(\.scope), [.toolPhotoCapture, .toolPhotoCapture])
        assertStoredIsFiltered(media.id, "capture_photo shutter")
    }

    func testAPlainCaptureAttachesNothingWithNoJobOpen() async throws {
        let provider = FakeStillProvider(.still(FilteredStill(image: filteredCanary,
                                                              scope: .toolPhotoCapture)))
        _ = try await CapturePhotoTool(cameraService: provider, jobEvidence: service)
            .execute(args: [:])
        XCTAssertTrue(service.jobMedia.isEmpty)
    }

    // MARK: - The phone's own camera and library

    func testAPhonePictureIsFilteredBeforeItIsStored() async throws {
        _ = try startJob()
        let filter = FakeStillFilter(replacement: filteredCanary)
        let outcome = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera, caption: "burner box")

        let itemId = try XCTUnwrap(outcome.itemId)
        XCTAssertEqual(filter.scopes, [.toolPhotoCapture])
        assertStoredIsFiltered(itemId, "phone camera")
        let media = try XCTUnwrap(service.jobMedia.first)
        XCTAssertEqual(media.origin, .phoneCamera)
        XCTAssertEqual(media.caption, "burner box")
        XCTAssertTrue(media.filterWasOn)
    }

    func testALibraryPictureTakesTheSameRoute() async throws {
        _ = try startJob()
        let filter = FakeStillFilter(replacement: filteredCanary)
        let outcome = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .photoLibrary)

        assertStoredIsFiltered(try XCTUnwrap(outcome.itemId), "photo library")
        XCTAssertEqual(service.jobMedia.first?.origin, .photoLibrary)
    }

    /// Fail closed. "We could not filter this" and "here are the raw pixels" must never be the
    /// same outcome — which is the whole reason the still chokepoint exists.
    func testAFilterThatCannotRunStoresNothingAtAll() async throws {
        _ = try startJob()
        let filter = FakeStillFilter(replacement: nil)
        let outcome = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)

        XCTAssertEqual(outcome, .filterUnavailable)
        XCTAssertTrue(service.jobMedia.isEmpty)
        XCTAssertNotNil(outcome.problem)
    }

    /// A wiring omission must not read as "nothing to filter".
    func testNoFilterWiredIsAlsoARefusal() async throws {
        _ = try startJob()
        let outcome = evidenceService(filter: nil, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)
        XCTAssertEqual(outcome, .filterUnavailable)
        XCTAssertTrue(service.jobMedia.isEmpty)
    }

    /// With the blur off, what is stored is the picture the technician actually took.
    func testWithTheFilterOffTheOriginalIsStored() async throws {
        _ = try startJob()
        let filter = FakeStillFilter(replacement: nil, passthrough: true)
        let outcome = evidenceService(filter: filter, filterOn: false)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)

        let itemId = try XCTUnwrap(outcome.itemId)
        let colour = try XCTUnwrap(storedColour(itemId))
        XCTAssertGreaterThan(colour.r, colour.b + 0.1, "the original should have been stored")
        XCTAssertFalse(try XCTUnwrap(service.jobMedia.first).filterWasOn)
    }

    func testNothingIsAttachedWithNoJobOpen() async throws {
        let filter = FakeStillFilter(replacement: filteredCanary)
        let outcome = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)
        XCTAssertEqual(outcome, .noOpenJob)
        XCTAssertTrue(filter.scopes.isEmpty, "the filter should not even be asked")
    }

    /// A paused job is still the job — the same `endedAt` rule the rest of the guided flow keys on.
    func testAPausedJobStillTakesEvidence() async throws {
        _ = try startJob()
        _ = try service.pauseSession()
        let filter = FakeStillFilter(replacement: filteredCanary)
        let outcome = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)
        XCTAssertNotNil(outcome.itemId)
        XCTAssertEqual(service.jobMedia.count, 1)
    }

    func testAClosedJobTakesNoMoreEvidence() async throws {
        _ = try startJob()
        _ = try service.endSession(outcome: .resolved)
        let filter = FakeStillFilter(replacement: filteredCanary)
        let outcome = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)
        XCTAssertEqual(outcome, .noOpenJob)
    }

    // MARK: - Where it lands on the record

    func testEvidenceTakenDuringATaskIsRecordedAgainstThatTask() async throws {
        _ = try startJob()
        let task = try service.addOperatorTask(title: "Clean the flame sensor", why: nil)
        _ = try service.startTask(id: task.id)

        let filter = FakeStillFilter(replacement: filteredCanary)
        _ = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .phoneCamera)

        XCTAssertEqual(service.jobMedia.first?.taskId, task.id)
        XCTAssertEqual(service.activeSession?.tasks.first?.evidence.photos.count, 1)
    }

    /// A photo taken after a selection was already made has to appear in it, or the review the
    /// technician is looking at would be missing the picture they just took.
    func testASelectionLearnsAboutAPhotoTakenAfterIt() async throws {
        _ = try startJob()
        let filter = FakeStillFilter(replacement: filteredCanary)
        let evidence = evidenceService(filter: filter, filterOn: true)
        _ = evidence.attach(imageData: try jpeg(rawCanary), origin: .photoLog)

        var selection = service.evidenceSelection()
        selection.includeAll()
        service.setEvidenceSelection(selection.confirmed())

        _ = evidence.attach(imageData: try jpeg(rawCanary), origin: .capture)

        let carried = service.evidenceSelection()
        XCTAssertEqual(carried.entries.count, 2)
        XCTAssertTrue(carried.reviewed)
        XCTAssertEqual(carried.includedCount, 1, "the new capture is offered, not assumed")
    }

    /// The selection survives a relaunch, because a report re-sent tomorrow has to be the same one.
    func testTheSelectionPersistsWithTheSession() async throws {
        let started = try startJob()
        let filter = FakeStillFilter(replacement: filteredCanary)
        _ = evidenceService(filter: filter, filterOn: true)
            .attach(imageData: try jpeg(rawCanary), origin: .photoLog, caption: "leak site")
        var selection = service.evidenceSelection()
        selection.setRole(.fault, for: selection.entries[0].itemId)
        service.setEvidenceSelection(selection.confirmed())
        _ = try service.endSession(outcome: .resolved)

        let reopened = FieldSessionService(sessionsRoot: sessionsRoot)
        let restored = try XCTUnwrap(reopened.history.first { $0.id == started.id })
        XCTAssertEqual(restored.media.count, 1)
        XCTAssertEqual(restored.media[0].caption, "leak site")
        XCTAssertTrue(restored.media[0].filterWasOn)
        XCTAssertEqual(restored.evidenceSelection?.entries.first?.role, .fault)
        XCTAssertTrue(restored.evidenceSelection?.reviewed == true)
    }
}

/// A chokepoint that answers a different way each time it is asked — the two-request shape
/// `capture_photo` uses to tell a reused stream frame from a fresh shutter.
@MainActor
final class SequencedProvider: FilteredStillProviding {
    private var results: [FilteredStillResult]
    private(set) var requests: [(scope: PrivacyFilterScope, source: FilteredStillSource)] = []

    init(results: [FilteredStillResult]) { self.results = results }

    func filteredStill(for scope: PrivacyFilterScope,
                       source: FilteredStillSource) async -> FilteredStillResult {
        requests.append((scope, source))
        return results.isEmpty ? .unavailable(.noStill) : results.removeFirst()
    }
}
