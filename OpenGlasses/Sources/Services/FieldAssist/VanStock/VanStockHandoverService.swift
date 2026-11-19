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
    /// The place in force for the list (Plan MK §2), which names the workbook's file.
    private let place: @MainActor () -> StockPlace.Kind

    init(service: VanStockService? = nil,
         place: (@MainActor () -> StockPlace.Kind)? = nil) {
        self.service = service ?? .shared
        self.place = place ?? { VanStockStore.shared.resolvedPlace.kind }
    }

    /// Build the handover and put it in front of the technician. False when there is nothing
    /// readable to send.
    @discardableResult
    func stage() -> Bool {
        discard()
        guard let url = Self.exportFile(service, kind: place()) else { return false }
        staged = Staged(id: url.deletingLastPathComponent().lastPathComponent,
                        message: service.handoverMessage(), fileURL: url)
        return true
    }

    /// The service's workbook, its file named for the place (Plan MK §3): "Store stock
    /// 2026-11-19.xlsx" for a store. The sheet inside already follows the place; the file name is
    /// set here, so the screen's Export and the handover name it the same way.
    static func exportFile(_ service: VanStockService, kind: StockPlace.Kind) -> URL? {
        guard let url = service.exportFile() else { return nil }
        let name = VanStockSheet.fileName(retitling: url.lastPathComponent, to: kind)
        guard name != url.lastPathComponent else { return url }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: renamed)
            return renamed
        } catch {
            return url
        }
    }

    /// Finished with it — sent, or not: the temporary workbook goes.
    func discard() {
        if let staged { try? FileManager.default.removeItem(at: staged.fileURL.deletingLastPathComponent()) }
        staged = nil
    }
}
