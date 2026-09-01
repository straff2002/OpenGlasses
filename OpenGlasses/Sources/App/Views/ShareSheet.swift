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

/// Supplies a protected export to the share sheet: the file keeps its generic on-disk name, while
/// the UI is offered the human-readable one as the item's title/subject. Used by both protected
/// export paths — clinical bundles and the diagnostics bundle — because the property that matters
/// (the filename never carries the title) is the same for both.
class ProtectedExportActivityItem: NSObject, UIActivityItemSource {
    private let fileURL: URL
    private let displayName: String

    init(fileURL: URL, displayName: String) {
        self.fileURL = fileURL
        self.displayName = displayName
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        fileURL
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        fileURL
    }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String {
        displayName
    }
}

/// A protected clinical export, by its lease.
final class MedicalExportActivityItem: ProtectedExportActivityItem {
    init(lease: MedicalExportLease) {
        super.init(fileURL: lease.fileURL, displayName: lease.displayName)
    }
}

/// A diagnostics bundle, by its lease.
final class DiagnosticExportActivityItem: ProtectedExportActivityItem {
    init(lease: DiagnosticExportLease) {
        super.init(fileURL: lease.fileURL, displayName: lease.displayName)
    }
}
