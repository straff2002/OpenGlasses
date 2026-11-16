import Foundation
import UIKit
import VisionKit

/// Plan LW P1 — photographed pages, made into the PDF a manual for a vault of your own is added
/// from. The same pages-to-PDF path My Manuals uses (`PersonalManualCapture`), without its library
/// reservation: a vault of your own has no manual count. The PDF then goes through
/// `ManualFileUpload.prepare`, and its pages are read by recognition when it is indexed.
@MainActor
enum ScannedPagesPDF {

    private final class ImageTransfer: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
        func jpeg() throws -> Data {
            let scale = min(1, 2200 / max(image.size.width, image.size.height))
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let cg = upright.cgImage else { throw CapturedManualStore.Failure.missingPage }
            return try CapturedManualMedia.jpeg(cg)
        }
    }

    /// The scan's pages as one PDF in a folder of its own; the caller removes the folder.
    static func pdf(from scan: VNDocumentCameraScan, title: String) async throws -> (pdf: URL, folder: URL) {
        guard (1...CapturedManualContract.maximumPages).contains(scan.pageCount) else {
            throw ManualFileUpload.failure(String(localized: "Photograph at most \(CapturedManualContract.maximumPages) pages at a time."))
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VaultScan-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        do {
            for index in 0..<scan.pageCount {
                let transfer = ImageTransfer(scan.imageOfPage(at: index))
                try await Task.detached(priority: .utility) {
                    let bytes = try autoreleasepool { try transfer.jpeg() }
                    try bytes.write(to: root.appendingPathComponent("\(index + 1).jpg"),
                                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }.value
            }
            let count = scan.pageCount
            let url = try await Task.detached(priority: .utility) {
                let data = try CapturedManualMedia.pdf(title: title, capturedAt: Int64(Date().timeIntervalSince1970), pageCount: count) {
                    try Data(contentsOf: root.appendingPathComponent("\($0).jpg"))
                }
                let url = root.appendingPathComponent("pages.pdf")
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return url
            }.value
            return (url, root)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }
}
