import SwiftUI
import UIKit

/// Identifiable wrapper for items to share via the iOS share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
    /// Called once the share provider finishes, with whether it completed. Shares that hand out a
    /// file the app must then delete use this to release it — cancellation included.
    var onComplete: ((Bool) -> Void)?
}

/// UIActivityViewController wrapper for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let onComplete {
            // Fires for success, cancel, and provider error alike — the only signal that says the
            // provider is done with the file.
            controller.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Supplies a protected clinical export to the share sheet: the file keeps its generic on-disk
/// name, while the UI is offered the human-readable one as the item's title/subject.
final class MedicalExportActivityItem: NSObject, UIActivityItemSource {
    private let lease: MedicalExportLease

    init(lease: MedicalExportLease) {
        self.lease = lease
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        lease.fileURL
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        lease.fileURL
    }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String {
        lease.displayName
    }
}
