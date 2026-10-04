import XCTest
@testable import OpenGlasses

/// A recorded job has one way off the phone — the bundle sent to the office — and this reads the
/// sources to hold it to that (Plan HE §1: "no other exit").
///
/// The roster (`OutboundFrameConsumer`) says a recorded job cannot be shared, saved to Photos or
/// attached to a report. A behavioural test cannot show that something is *absent*; the two
/// failures this surface has shipped before were both a path nobody listed. So, like
/// `OutboundFrameConsumerTests`, this looks at the code: the files that hold a recorded job call
/// nothing that shares, exports or files a recording elsewhere, and nothing else builds a path
/// into a job's recording folder.
final class JobRecordingExitTests: XCTestCase {

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Every file that holds, moves or shows a recorded job.
    private static let recordedJobFiles = [
        "Services/FieldAssist/Job/JobRecordingCoordinator.swift",
        "Services/FieldAssist/Job/JobRecordingCoordinator+App.swift",
        "Services/OfficeSync/JobRecordingCaptureStore.swift",
        "Services/OfficeSync/JobRecordingBundleStore.swift",
        "Services/OfficeSync/JobRecordingSyncService.swift",
        "App/Views/Job/JobRecordingSection.swift",
    ]

    /// The ways a file leaves the app that a recorded job must never take.
    private static let exits = [
        "GlassesPhotoAlbum", "PHPhotoLibrary", "PHAssetCreationRequest", "UISaveVideoAtPathToSavedPhotosAlbum",
        "UIActivityViewController", "ShareLink", "ShareItem", "pendingShareItem", "fileExporter",
        "UIDocumentInteractionController", "UIDocumentPickerViewController", "QLPreviewController",
        "RecordingFiler", "recordingFolderURL", "recordingsDirectory",
        "attachClip(", "attachPhoto(", "DeliveryRequest", "MFMailComposeViewController", "URLSession",
        "UIPasteboard",
    ]

    /// The code of a file, comments left out: a comment naming an API is a reference, not a call.
    private func code(_ relative: String) throws -> String {
        try String(contentsOf: Self.sourcesRoot.appendingPathComponent(relative), encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
            .joined(separator: "\n")
    }

    func testTheFilesThatHoldARecordedJobCallNoOtherExit() throws {
        for file in Self.recordedJobFiles {
            let text = try code(file)
            XCTAssertFalse(text.isEmpty, "\(file) is missing or empty — the guard would pass on nothing")
            for exit in Self.exits {
                XCTAssertFalse(text.contains(exit), "\(file) calls \(exit): a recorded job may only go to the office")
            }
        }
    }

    /// Only the two stores build a path into a job's `recording` folder. Anything else reaching in
    /// would be a reader nobody argued for.
    func testOnlyTheTwoStoresBuildAPathIntoAJobsRecordingFolder() throws {
        let allowed: Set<String> = ["JobRecordingCaptureStore.swift", "JobRecordingBundleStore.swift"]
        guard let walker = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("Could not enumerate the sources")
        }
        var builders: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(#"appendingPathComponent("recording""#) { builders.insert(url.lastPathComponent) }
        }
        XCTAssertEqual(builders, allowed)
    }

    /// The recorded parts and the sealed chunks are read by name in exactly the places that record,
    /// seal and send them.
    func testOnlyTheRecorderTheSealAndTheSenderReadTheMedia() throws {
        guard let walker = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil) else {
            return XCTFail("Could not enumerate the sources")
        }
        var partReaders: Set<String> = []
        var chunkReaders: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".partFile(sessionID:") { partReaders.insert(url.lastPathComponent) }
            if text.contains(".chunkFile(") { chunkReaders.insert(url.lastPathComponent) }
        }
        XCTAssertEqual(partReaders, ["JobRecordingCoordinator.swift"])
        XCTAssertEqual(chunkReaders, ["JobRecordingSyncService.swift"])
    }

    /// The exit itself goes to the office and to nothing else: the sender's only use of a chunk is
    /// handing it to the office transport.
    func testTheSenderHandsChunksOnlyToTheOfficeTransport() throws {
        let sender = try code("Services/OfficeSync/JobRecordingSyncService.swift")
        let uses = sender.components(separatedBy: "\n").filter { $0.contains(".chunkFile(") }
        XCTAssertEqual(uses.count, 1)
        XCTAssertTrue(sender.contains("seams.transport.publishRecordingChunk("))
        XCTAssertTrue(sender.contains("MedicalEgressGuard.check(.jobRecordingOfficeSync)"),
                      "the medical local-only rule is asked where the bytes would leave")
    }
}
