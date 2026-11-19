import Foundation

/// The end-of-shift handover, staged and waiting for the technician (Plan IH §8).
///
/// Staged rather than sent: asking for it by voice builds the workbook and the short text, and the
/// app shows both. Nothing has left the phone until the technician sends it from that sheet.
@MainActor
final class VanStockHandoverService: ObservableObject {

    static let shared = VanStockHandoverService()

    struct Staged: Equatable, Identifiable {
        let id: String
        /// The text that goes with the workbook: what to top up, what is on order, what needs
        /// counting, what came back.
        let message: String
        /// The workbook, in a temporary folder of its own.
        let fileURL: URL
    }

    @Published private(set) var staged: Staged?

    private let service: VanStockService

    init(service: VanStockService? = nil) {
        self.service = service ?? .shared
    }

    /// Build the handover and put it in front of the technician. False when there is nothing
    /// readable to send.
    @discardableResult
    func stage() -> Bool {
        discard()
        // The service names the file for the place in force, as the screen's Export does.
        guard let url = service.exportFile() else { return false }
        staged = Staged(id: url.deletingLastPathComponent().lastPathComponent,
                        message: service.handoverMessage(), fileURL: url)
        return true
    }

    /// Finished with it — sent, or not: the temporary workbook goes.
    func discard() {
        if let staged { try? FileManager.default.removeItem(at: staged.fileURL.deletingLastPathComponent()) }
        staged = nil
    }
}
