import PDFKit
import XCTest
@testable import OpenGlasses

/// What a job with a clip on it actually produces: the lines in the work order, the fields in the
/// machine-readable record, and the attachments the composer is handed (Plan FO P2b).
///
/// Asserted against the produced documents rather than the code that wrote them — the same rule
/// `EvidenceExportTests` follows, and for the same reason: a test of the draw calls would pass
/// happily while the record said nothing about a clip that went out.
@MainActor
final class JobClipDeliveryTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDelivery-\(UUID().uuidString)", isDirectory: true)
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

    private func picture(_ hue: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 450), format: format)
            .image { context in
                UIColor(hue: hue, saturation: 0.9, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 450))
            }
            .jpegData(compressionQuality: 0.9)!
    }

    /// One finished job: a photograph and two clips, everything chosen.
    private func makeJob(clipBytes: [Int] = [400_000, 900_000])
        throws -> (service: FieldSessionService, session: FieldSession, directory: URL) {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let session = try service.startSession(vaultId: "refrigeration", assetId: nil,
                                               mode: .aiOnly, jobReference: "1005")
        let task = try service.addOperatorTask(title: "Condensate trap", why: "Blocked")
        _ = try service.startTask(id: task.id)
        service.attachPhoto(picture(0.1), caption: "leak site", origin: .photoLog,
                            filterWasOn: true)
        for (index, bytes) in clipBytes.enumerated() {
            service.attachClip(Data(repeating: UInt8(index + 1), count: bytes),
                               posterJPEG: picture(0.5), caption: "clip \(index + 1)",
                               durationSeconds: TimeInterval(10 + index * 5),
                               filterWasOn: true, cutShort: index == 1)
        }
        _ = try service.completeTask(id: task.id, note: "New trap fitted and tested.")

        var selection = service.evidenceSelection()
        selection.includeAll()
        service.setEvidenceSelection(selection.confirmed())
        let finished = try service.endSession(outcome: .resolved)
        return (service, finished, tempRoot.appendingPathComponent(finished.id, isDirectory: true))
    }

    private func pdfText(_ directory: URL, clipPlan: ClipDeliveryPlan) throws -> String {
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: directory,
                                                                 clipPlan: clipPlan))
        let url = tempRoot.appendingPathComponent("\(UUID().uuidString)-work_order.pdf")
        try SessionExporter.writePDF(document, to: url,
                                     photosDirectory: directory.appendingPathComponent("photos"),
                                     clipPlan: clipPlan)
        return try XCTUnwrap(PDFDocument(url: url)?.string)
    }

    private func imageCount(in url: URL) -> Int {
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

    // MARK: - The work order

    /// A clip is named, never drawn. The picture count has to stay at the one photograph: a PDF
    /// that embedded a poster frame would be claiming to show a video it cannot play.
    func testTheWorkOrderNamesEachClipAndEmbedsNoVideo() throws {
        let job = try makeJob()
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))
        let url = tempRoot.appendingPathComponent("work_order.pdf")
        try SessionExporter.writePDF(document, to: url,
                                     photosDirectory: job.directory
                                         .appendingPathComponent("photos"))
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)

        XCTAssertTrue(text.contains("Photos and clips"),
                      "a job with clips must not head its evidence section 'Photos'")
        XCTAssertTrue(text.contains("clip 1"), text)
        XCTAssertTrue(text.contains("clip 2"), text)
        XCTAssertTrue(text.contains("10 seconds"), text)
        XCTAssertTrue(text.contains("15 seconds"), text)
        XCTAssertTrue(text.contains("cut short"), "a clip that ended early must say so")
        XCTAssertEqual(imageCount(in: url), 1,
                       "exactly the one photograph; a clip's poster is not the report's picture")
    }

    func testTheWorkOrderSaysWhichClipWentWithItAndWhichDidNot() throws {
        let job = try makeJob(clipBytes: [400_000, 40 * 1024 * 1024])
        let record = WorkRecord(session: job.session, vaultName: "Refrigeration")
        let partition = AttachmentBudget.standard(for: .email)
            .partition(clips: record.includedClips,
                       reservedBytes: FieldSessionService.reportFileReserveBytes)
        let plan = ClipDeliveryPlan(channel: .email, partition: partition)

        let text = try pdfText(job.directory, clipPlan: plan)
        XCTAssertTrue(text.contains("sent separately"), text)
        XCTAssertTrue(text.contains("over the size limit for Email"), text)
    }

    /// A job whose review was skipped prints what it always printed. The clip is still on the
    /// device; it simply was not chosen.
    func testASkippedReviewNamesNoClips() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        let started = try service.startSession(vaultId: "refrigeration", assetId: nil,
                                               mode: .aiOnly, jobReference: "1006")
        service.attachClip(Data(repeating: 3, count: 1_000), posterJPEG: nil,
                           caption: "not chosen", durationSeconds: 8, filterWasOn: false,
                           cutShort: false)
        service.setEvidenceSelection(.skipped())
        _ = try service.endSession(outcome: .resolved)

        let directory = tempRoot.appendingPathComponent(started.id, isDirectory: true)
        let text = try pdfText(directory, clipPlan: .undecided)
        XCTAssertFalse(text.contains("Photos and clips"), text)
        XCTAssertFalse(text.contains("not chosen"), text)
    }

    // MARK: - The machine-readable record

    func testTheJSONListsEachClipWithItsDecisionAndHowItTravelled() throws {
        let job = try makeJob(clipBytes: [400_000, 40 * 1024 * 1024])
        let record = WorkRecord(session: job.session, vaultName: "Refrigeration")
        let partition = AttachmentBudget.standard(for: .email)
            .partition(clips: record.includedClips,
                       reservedBytes: FieldSessionService.reportFileReserveBytes)
        let plan = ClipDeliveryPlan(channel: .email, partition: partition)
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory,
                                                                 clipPlan: plan))
        let clips = try XCTUnwrap(document.clips)
        XCTAssertEqual(clips.count, 2)

        let small = try XCTUnwrap(clips.first { $0.caption == "clip 1" })
        XCTAssertEqual(small.included, true)
        XCTAssertEqual(small.attached, true)
        XCTAssertEqual(small.durationSeconds, 10)
        XCTAssertEqual(small.bytes, 400_000)
        XCTAssertNil(small.notAttachedReason)
        XCTAssertFalse(small.cutShort)

        let big = try XCTUnwrap(clips.first { $0.caption == "clip 2" })
        XCTAssertEqual(big.included, true)
        XCTAssertEqual(big.attached, false, "over budget is recorded, never silently dropped")
        XCTAssertNotNil(big.notAttachedReason)
        XCTAssertTrue(big.cutShort)
    }

    /// An export taken for the archive has no channel, so it says nothing about attachment rather
    /// than guessing at one.
    func testAnArchiveExportLeavesAttachedUnanswered() throws {
        let job = try makeJob()
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))
        let clips = try XCTUnwrap(document.clips)
        XCTAssertEqual(clips.count, 2)
        XCTAssertTrue(clips.allSatisfy { $0.attached == nil })
        XCTAssertTrue(clips.allSatisfy { $0.included == true })
    }

    /// A record written before clips existed decodes with no `clips` key at all.
    func testAnAuditWrittenBeforeClipsExistedStillDecodes() throws {
        let job = try makeJob()
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try encoder.encode(document)) as? [String: Any])
        object.removeValue(forKey: "clips")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            SessionExport.self,
            from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.clips)
        XCTAssertEqual(decoded.photos.count, document.photos.count)
    }

    // MARK: - What the composer is handed

    func testTheAttachmentsCarryTheClipsThatFitAndNameTheOnesThatDoNot() throws {
        let job = try makeJob(clipBytes: [400_000, 40 * 1024 * 1024])
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id)

        XCTAssertEqual(delivery.attachments.filter { $0.kind == .video }.count, 1)
        XCTAssertEqual(delivery.clipPlan.overBudget.count, 1)
        XCTAssertEqual(delivery.clipItems.count, 2)
        // The name a recipient sees is the job, not the device's uuid.
        let video = try XCTUnwrap(delivery.attachments.first { $0.kind == .video })
        XCTAssertTrue(video.filename.hasPrefix("job-1005-clip-"), video.filename)
        XCTAssertEqual(video.kind.mimeType, "video/mp4")
        XCTAssertEqual(video.kind.uti, "public.mpeg-4")
    }

    /// Re-sending a past job on the same channel has to reproduce the same partition, or a
    /// "re-send" is a different delivery wearing the same name.
    func testResendingReproducesTheSamePartition() throws {
        let job = try makeJob(clipBytes: [400_000, 40 * 1024 * 1024])
        let first = job.service.reportDelivery(for: .email, sessionId: job.session.id)
        let second = job.service.reportDelivery(for: .email, sessionId: job.session.id)
        XCTAssertEqual(first.clipPlan, second.clipPlan)
        XCTAssertEqual(first.attachments.map(\.filename), second.attachments.map(\.filename))
    }

    func testAChannelThatCannotCarryFilesGetsNoClipsAndSaysWhy() throws {
        let job = try makeJob()
        let delivery = job.service.reportDelivery(for: .whatsapp, sessionId: job.session.id)
        XCTAssertTrue(delivery.attachments.filter { $0.kind == .video }.isEmpty)
        XCTAssertEqual(delivery.clipPlan.overBudget.count, 2)
        XCTAssertTrue(try XCTUnwrap(delivery.clipPlan.overBudget.first).reason
            .contains("can't carry a file"))
    }

    func testTheComposerBodyNamesTheClipsThatCouldNotRideAlong() throws {
        let job = try makeJob(clipBytes: [40 * 1024 * 1024])
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id)
        let record = WorkRecord(session: job.session, vaultName: "Refrigeration")
        let request = DeliveryRequest.make(record: record, channel: .email,
                                           recipients: ["office@example.com"],
                                           attachments: delivery.attachments,
                                           clipPlan: delivery.clipPlan,
                                           clipItems: delivery.clipItems)
        let model = ReportComposerModel(request: request)
        XCTAssertTrue(model.filledBody.contains("shared separately"), model.filledBody)
        XCTAssertTrue(request.confirmation.contains("shared separately"), request.confirmation)
        XCTAssertEqual(request.clipsToShareSeparately.count, 1)
    }

    func testAReportWithEveryClipAttachedSaysSoAndOffersNoShare() throws {
        let job = try makeJob()
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id)
        let record = WorkRecord(session: job.session, vaultName: "Refrigeration")
        let request = DeliveryRequest.make(record: record, channel: .email, recipients: ["a@b.c"],
                                           attachments: delivery.attachments,
                                           clipPlan: delivery.clipPlan,
                                           clipItems: delivery.clipItems)
        XCTAssertEqual(request.clipsSharedSeparately, 0)
        XCTAssertTrue(request.clipsToShareSeparately.isEmpty)
        XCTAssertNil(ReportComposerModel(request: request).clipNote)
        XCTAssertTrue(request.confirmation.contains("2 clips go with it"), request.confirmation)
    }

    // MARK: - What a clip is on disk

    func testAClipAndItsPosterAreFiledUnderTheSessionWithTheirOwnMeasurements() throws {
        let job = try makeJob(clipBytes: [12_345])
        let clip = try XCTUnwrap(job.session.media.first { $0.kind == .clip })
        XCTAssertEqual(clip.byteCount, 12_345)
        XCTAssertEqual(clip.durationSeconds, 10)
        XCTAssertEqual(clip.origin, .clipRecord)
        XCTAssertTrue(clip.id.hasSuffix(".mp4"))
        let photos = job.directory.appendingPathComponent("photos")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: photos.appendingPathComponent(clip.id).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: photos.appendingPathComponent(try XCTUnwrap(clip.posterId)).path))
    }

    /// Evidence cannot be attached to a job that is not open — the same rule photographs follow.
    func testNoClipIsFiledAgainstAClosedJob() throws {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        _ = try service.startSession(vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                     jobReference: "1007")
        _ = try service.endSession(outcome: .resolved)
        XCTAssertNil(service.attachClip(Data(repeating: 1, count: 100), posterJPEG: nil,
                                        caption: "late", durationSeconds: 3, filterWasOn: false,
                                        cutShort: false))
    }
}
