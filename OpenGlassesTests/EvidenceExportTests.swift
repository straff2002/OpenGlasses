import PDFKit
import XCTest
@testable import OpenGlasses

/// What actually comes out of the exporter once the technician has chosen (Plan FO P2a).
///
/// Asserted against the **document**, not against the code that wrote it: the embedded image
/// XObjects are counted out of the produced PDF and its text is read back with PDFKit. A test that
/// checked the draw calls would pass just as happily if the pictures never reached the page.
@MainActor
final class EvidenceExportTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvidenceExport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A distinctly coloured picture, so two embedded images are never the same object and cannot
    /// be de-duplicated into one by the PDF writer.
    private func picture(_ hue: CGFloat, size: CGSize = CGSize(width: 900, height: 675)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: hue, saturation: 0.9, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 3, height: size.height))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// One finished job with three photographs on it: two on a task, one against the job.
    private func makeJob(captions: [String] = ["leak site", "new trap", "the van"],
                         select: ((inout EvidenceSelection, [JobMediaItem]) -> Void)? = nil)
        throws -> (service: FieldSessionService, directory: URL, media: [JobMediaItem]) {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil,
                                               mode: .aiOnly, jobReference: "1005")
        let task = try service.addOperatorTask(title: "Condensate trap", why: "Blocked")
        _ = try service.startTask(id: task.id)
        service.attachPhoto(picture(0.0), caption: captions[0], origin: .photoLog, filterWasOn: true)
        service.attachPhoto(picture(0.33), caption: captions[1], origin: .photoLog, filterWasOn: true)
        _ = try service.completeTask(id: task.id, note: "New trap fitted and tested.")
        service.attachPhoto(picture(0.66), caption: captions[2], origin: .capture, filterWasOn: false)

        let media = service.jobMedia
        if let select {
            var selection = service.evidenceSelection()
            select(&selection, media)
            service.setEvidenceSelection(selection.confirmed())
        }
        _ = try service.endSession(outcome: .resolved)
        return (service, tempRoot.appendingPathComponent(session.id, isDirectory: true), media)
    }

    private func render(_ directory: URL, name: String = "work_order.pdf",
                        provenance: AIProvenance? = nil) throws -> URL {
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: directory,
                                                                 provenance: provenance))
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try SessionExporter.writePDF(document, to: url,
                                     photosDirectory: directory.appendingPathComponent("photos"))
        return url
    }

    // MARK: - Reading the produced PDF

    /// Count the image XObjects the document actually embeds.
    private func embeddedImageCount(in url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { return -1 }
        var total = 0
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number), let dictionary = page.dictionary else {
                continue
            }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
                  let resources else { continue }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
                  let xobjects else { continue }
            withUnsafeMutablePointer(to: &total) { counter in
                CGPDFDictionaryApplyFunction(xobjects, { _, value, info in
                    var stream: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                          let streamDictionary = CGPDFStreamGetDictionary(stream) else { return }
                    var subtype: UnsafePointer<Int8>?
                    guard CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype),
                          let subtype, String(cString: subtype) == "Image" else { return }
                    info?.assumingMemoryBound(to: Int.self).pointee += 1
                }, counter)
            }
        }
        return total
    }

    private func text(of url: URL) throws -> String {
        try XCTUnwrap(PDFDocument(url: url)?.string)
    }

    /// The same text with every space and line break taken out.
    ///
    /// A stored photo's file name is a long ISO timestamp and a uuid fragment, and the layout
    /// wraps it — so a plain `contains` would fail on a bullet that is genuinely there. What is
    /// under test is whether the name reached the page, not where the line broke.
    private func unbroken(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    // MARK: - The pictures that were chosen, and only those

    func testThePDFEmbedsExactlyTheSelectedPicturesAndNoneOfTheOthers() throws {
        let job = try makeJob { selection, media in
            selection.setIncluded(true, for: media[0].id)
            selection.setIncluded(true, for: media[1].id)
            selection.setIncluded(false, for: media[2].id)
        }
        let pdf = try render(job.directory)

        XCTAssertEqual(embeddedImageCount(in: pdf), 2)
        let body = try text(of: pdf)
        XCTAssertTrue(body.contains("leak site"), "a selected caption is missing")
        XCTAssertTrue(body.contains("new trap"), "a selected caption is missing")
        XCTAssertFalse(body.contains("the van"), "an unselected photo reached the document")
        XCTAssertFalse(unbroken(body).contains(unbroken(job.media[2].id)),
                       "an unselected photo's file name reached the document")
    }

    /// Fault, then Fix, then unmarked — and each picture's caption is real text under it, so the
    /// order can be read back out of the document rather than inferred.
    func testTheOrderIsFaultThenFixThenUnmarked() throws {
        let job = try makeJob(captions: ["alpha caption", "bravo caption", "charlie caption"]) {
            selection, media in
            selection.includeAll()
            selection.setRole(.fix, for: media[0].id)
            selection.setRole(.fault, for: media[1].id)
        }
        let body = try text(of: try render(job.directory))

        let fault = try XCTUnwrap(body.range(of: "bravo caption"))
        let fix = try XCTUnwrap(body.range(of: "alpha caption"))
        XCTAssertTrue(fault.lowerBound < fix.lowerBound, "Fault must print before Fix")
        XCTAssertTrue(body.contains("The fault"))
        XCTAssertTrue(body.contains("The fix"))
        // The unmarked one was taken against the job rather than the task, so it prints in its own
        // group after the task's.
        let job3 = try XCTUnwrap(body.range(of: "charlie caption"))
        XCTAssertTrue(fix.lowerBound < job3.lowerBound)
        XCTAssertTrue(body.contains(EvidenceRenderPlan.jobLevelTitle))
    }

    /// No marks at all is an ordinary job, not a degenerate one.
    func testAJobWithNoMarksStillPrintsItsPicturesInCaptureOrder() throws {
        let job = try makeJob { selection, _ in selection.includeAll() }
        let pdf = try render(job.directory)

        XCTAssertEqual(embeddedImageCount(in: pdf), 3)
        let body = try text(of: pdf)
        XCTAssertFalse(body.contains("The fault"))
        XCTAssertFalse(body.contains("The fix"))
    }

    /// The task's own name heads its pictures, so the record reads the way the work does.
    func testPicturesAreGroupedUnderTheirTask() throws {
        let job = try makeJob { selection, _ in selection.includeAll() }
        let body = try text(of: try render(job.directory))
        let task = try XCTUnwrap(body.range(of: "Condensate trap"))
        let loose = try XCTUnwrap(body.range(of: EvidenceRenderPlan.jobLevelTitle))
        XCTAssertTrue(task.lowerBound < loose.lowerBound)
    }

    // MARK: - Skipping

    /// The whole point of `reviewed` being false: a job that skipped the step produces the
    /// document the app has always produced — the bullet list, and not one embedded picture.
    func testSkippingReproducesTheTextOnlyWorkOrder() throws {
        let job = try makeJob(select: nil)
        let pdf = try render(job.directory)

        XCTAssertEqual(embeddedImageCount(in: pdf), 0, "a skipped review must send no pictures")
        let body = unbroken(try text(of: pdf))
        for item in job.media {
            XCTAssertTrue(body.contains(unbroken(item.id)),
                          "the bullet list should still name every photo by file")
        }
    }

    /// Explicitly saying "skip photos" is the same document, and is not the same value as
    /// excluding everything one by one.
    func testAnExplicitSkipIsAlsoTheTextOnlyWorkOrder() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil,
                                               mode: .aiOnly, jobReference: "1006")
        service.attachPhoto(picture(0.1), caption: "gauge", origin: .photoLog, filterWasOn: false)
        service.setEvidenceSelection(EvidenceSelection.skipped())
        _ = try service.endSession(outcome: .resolved)

        let directory = tempRoot.appendingPathComponent(session.id, isDirectory: true)
        let pdf = try render(directory)
        XCTAssertEqual(embeddedImageCount(in: pdf), 0)
        XCTAssertTrue(try text(of: pdf).contains("gauge"), "the bullet list still names it")
    }

    /// Reviewed and every picture unticked is a different answer: no bullet list either, because
    /// the technician was asked and said no.
    func testDeliberatelyExcludingEverythingSendsNoPicturesAndNoList() throws {
        let job = try makeJob { selection, _ in selection.excludeAll() }
        let pdf = try render(job.directory)
        XCTAssertEqual(embeddedImageCount(in: pdf), 0)
        let body = try text(of: pdf)
        XCTAssertFalse(body.contains("leak site"))
    }

    // MARK: - Re-sending

    /// A report re-sent from a past job has to be the report that went out. Same selection, same
    /// pictures, same order, same text.
    func testReSendingAPastJobReproducesTheSamePDF() throws {
        let job = try makeJob { selection, media in
            selection.includeAll()
            selection.setRole(.fault, for: media[1].id)
        }
        // Both renders get the **same** provenance. Its footer carries a whole-second timestamp of
        // when the PDF was made, so two renders that straddle a second boundary differ by design —
        // and on a loaded machine they do. Pinning it is what makes this test about the thing it
        // claims to be about: the same selection producing the same evidence, in the same order,
        // with the same text. Nothing else here is relaxed.
        let provenance = AIProvenance(modelIdentifier: "test-model", providerClass: .cloud,
                                      promptVersionDigest: "deadbeef",
                                      generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let first = try render(job.directory, name: "first.pdf", provenance: provenance)
        let second = try render(job.directory, name: "second.pdf", provenance: provenance)

        XCTAssertEqual(embeddedImageCount(in: first), embeddedImageCount(in: second))
        XCTAssertEqual(try text(of: first), try text(of: second))
    }

    // MARK: - Size

    /// Twenty-odd photographs still produce a file somebody can attach to an email.
    func testATwentyPhotoJobStaysInsideTheBudget() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil,
                                               mode: .aiOnly, jobReference: "1007")
        for index in 0..<22 {
            service.attachPhoto(picture(CGFloat(index) / 22, size: CGSize(width: 2_000, height: 1_500)),
                                caption: "picture \(index)", origin: .photoLog, filterWasOn: false)
        }
        var selection = service.evidenceSelection()
        selection.includeAll()
        service.setEvidenceSelection(selection.confirmed())
        _ = try service.endSession(outcome: .resolved)

        let pdf = try render(tempRoot.appendingPathComponent(session.id, isDirectory: true))
        XCTAssertEqual(embeddedImageCount(in: pdf), 22)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int)
        XCTAssertLessThan(size, EvidenceImageBudget.standard.totalByteCeiling,
                          "a 22-photo work order came out at \(size) bytes")
    }

    // MARK: - The JSON

    func testTheAuditJSONCarriesIncludedAndRole() throws {
        let job = try makeJob { selection, media in
            selection.setIncluded(true, for: media[0].id)
            selection.setRole(.fault, for: media[0].id)
            selection.setIncluded(false, for: media[2].id)
        }
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))

        XCTAssertEqual(document.photos.count, 3)
        let first = try XCTUnwrap(document.photos.first { $0.path == job.media[0].id })
        XCTAssertEqual(first.included, true)
        XCTAssertEqual(first.role, "fault")
        let last = try XCTUnwrap(document.photos.first { $0.path == job.media[2].id })
        XCTAssertEqual(last.included, false)
        XCTAssertNil(last.role)
    }

    /// Never reviewed is a different fact from "the technician left it out", and the JSON says so
    /// by leaving the field absent rather than writing false.
    func testAnUnreviewedJobLeavesIncludedUnstated() throws {
        let job = try makeJob(select: nil)
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))
        XCTAssertTrue(document.photos.allSatisfy { $0.included == nil })

        let encoded = try JSONEncoder().encode(document.photos)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"included\""))
    }

    /// An export written before any of this existed still decodes.
    func testALegacyPhotoRefDecodes() throws {
        let json = """
        {"timestamp":"2026-01-01T00:00:00Z","path":"a.jpg","caption":"gauge"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExport.PhotoRef.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.path, "a.jpg")
        XCTAssertNil(decoded.included)
        XCTAssertNil(decoded.role)
    }

    // MARK: - Downscaling

    func testTheEmbeddedCopyIsTheDownscaledOne() throws {
        let source = try XCTUnwrap(UIImage(data: picture(0.5, size: CGSize(width: 3_000,
                                                                           height: 2_250))))
        let plan = EvidenceImageBudget.standard.plan(photoCount: 30)
        let small = EvidenceImageRenderer.downscaled(source, plan: plan)

        XCTAssertEqual(max(small.size.width, small.size.height), plan.longEdge, accuracy: 1)
        XCTAssertEqual(small.size.width / small.size.height, 3_000.0 / 2_250.0, accuracy: 0.01)
    }

    func testASmallPictureIsNotBlownUp() throws {
        let source = try XCTUnwrap(UIImage(data: picture(0.5, size: CGSize(width: 200, height: 150))))
        let small = EvidenceImageRenderer.downscaled(source, plan: EvidenceImageBudget.standard
            .plan(photoCount: 1))
        XCTAssertEqual(small.size.width, 200, accuracy: 1)
    }
}
