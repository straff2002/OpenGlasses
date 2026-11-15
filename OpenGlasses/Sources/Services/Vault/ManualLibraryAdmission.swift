import Foundation
import PDFKit

/// One process-wide admission lock. Installation is synchronous and atomic with respect to other
/// admissions; indexing happens afterwards, so an interrupted index still holds its manual slot.
enum ManualLibraryAdmission {
    final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var reservations: [UUID: ManualQuota.Item] = [:]
        // Its own lock: the read paths on the main actor reach the history without waiting for an
        // admission that is measuring or hashing a large manual under `lock`.
        let additionsLock = NSLock()
        var storedAdditions: ManualAdditionHistoryStore = ManualLibraryAdmission.makeAdditionStore()
    }
    private static let state = State()

    /// The new-manual allowance's history (Plan JK §8). Swappable so tests use an in-memory store.
    static var additions: ManualAdditionHistoryStore {
        get { state.additionsLock.lock(); defer { state.additionsLock.unlock() }; return state.storedAdditions }
        set { state.additionsLock.lock(); state.storedAdditions = newValue; state.additionsLock.unlock() }
    }

    /// The unit-test host never reaches the live keychain or iCloud store: a headless run may be
    /// unsigned, and a test must not spend or erase the developer's own allowance.
    private static func makeAdditionStore() -> ManualAdditionHistoryStore {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return ManualAdditionHistoryStore(backend: InMemoryManualAdditionBackend(), enforced: false)
        }
        let backend = LiveManualAdditionBackend()
        let store = ManualAdditionHistoryStore(backend: backend)
        backend.onExternalChange = { [weak store] in _ = try? store?.load() }
        return store
    }

    /// The file a document's fingerprint is taken from: the uploaded original, never the
    /// app-generated reading copy; a publisher document's bundled original when it has one.
    static func originalRelativePath(_ manifest: VaultManifest, _ document: VaultDocument) -> String {
        document.personalReadingCopy == true
            ? manifest.documentRelativePath(document)
            : manifest.documentSourceRelativePath(document) ?? manifest.documentRelativePath(document)
    }

    private static var now: Date { FieldAssistEntitlement.shared.clock() }

    /// A read from these manuals (an answer cited one, or a page was opened) ends their undo.
    static func noteRead(identities: [String]) {
        guard !identities.isEmpty, let limits = FieldAssistEntitlement.shared.manualLimits() else { return }
        additions.noteRead(identities: identities, limits: limits, now: now)
    }

    /// After a removal: give back an unread addition made within the undo window. Removal never
    /// waits on or fails because of the allowance.
    @discardableResult
    static func noteRemoved(identity: String) -> Bool {
        additions.noteRemoved(identity: identity, limits: FieldAssistEntitlement.shared.manualLimits(), now: now)
    }

    /// The allowance for the upload sheet; nil without one, or when the history is unreadable.
    static func allowanceStatus() -> ManualAdditionAllowance.Status? {
        additions.status(limits: FieldAssistEntitlement.shared.manualLimits(), now: now)
    }
    enum Failure: LocalizedError {
        case refused(String)
        var errorDescription: String? { if case .refused(let text) = self { return text }; return nil }
    }

    static func pageCount(_ url: URL) throws -> Int {
        guard url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url), !pdf.isLocked,
              pdf.pageCount > 0 else { throw Failure.refused(String(localized: "This manual needs an unlocked, readable PDF with numbered pages.")) }
        return pdf.pageCount
    }

    static func inventory() throws -> [ManualQuota.Item] {
        var items: [ManualQuota.Item] = []
        let registry = VaultImporter.registryDirectory
        let files = FileManager.default.fileExists(atPath: registry.path)
            ? try FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil) : []
        // A corrupt/protected manifest cannot silently disappear from quota accounting.
        let manifests = try files.filter { $0.pathExtension == "json" }.map {
            try JSONDecoder().decode(VaultManifest.self, from: Data(contentsOf: $0))
        }
        for manifest in manifests where manifest.isPersonalLibrary {
            let root = VaultImporter.baselineDirectory(for: manifest.id)
            for document in manifest.documents {
                let path = manifest.documentSourceRelativePath(document) ?? manifest.documentRelativePath(document)
                let pages = try? pageCount(root.appendingPathComponent(path))
                items.append(.init(id: identity(manifest.id, document.file), pages: pages))
            }
        }
        guard Set(items.map(\.id)).count == items.count else {
            throw Failure.refused(ManualQuota.Verdict.unavailable.message!)
        }
        return items
    }

    static func identity(_ vault: String, _ file: String) -> String { "\(vault)/\(file)" }

    private static func held(excluding token: UUID? = nil) throws -> [ManualQuota.Item] {
        var items = Dictionary(uniqueKeysWithValues: try inventory().map { ($0.id, $0) })
        for (key, item) in state.reservations where key != token {
            if let old = items[item.id] {
                items[item.id] = .init(id: item.id, pages: max(old.pages ?? 0, item.pages ?? 0))
            } else { items[item.id] = item }
        }
        return Array(items.values)
    }

    static func reserveCapture(identity: String? = nil) throws -> UUID {
        state.lock.lock(); defer { state.lock.unlock() }
        guard FieldAssistEntitlement.shared.has(.personalManuals) else { throw Failure.refused(MyManualsPaywallCopy.locked) }
        let token = UUID()
        let held = try held()
        let id = identity ?? "pending:\(token.uuidString)"
        let item = ManualQuota.Item(id: id, pages: held.first { $0.id == id }?.pages ?? 1)
        let limits = FieldAssistEntitlement.shared.manualLimits()
        if let message = ManualQuota.decide(limits: limits, held: held,
                                           replacing: identity.map { [$0] } ?? [], adding: [item]).message {
            throw Failure.refused(message)
        }
        // A photographed manual has new bytes, so it is a new manual unless it replaces one held.
        if identity == nil { try additions.checkNewManual(limits: limits, now: now) }
        state.reservations[token] = item
        return token
    }

    static func release(_ token: UUID) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.reservations[token] = nil
    }

    static func validateCapture(_ token: UUID, pages: Int) throws {
        state.lock.lock(); defer { state.lock.unlock() }
        guard FieldAssistEntitlement.shared.has(.personalManuals), let item = state.reservations[token] else {
            throw Failure.refused(String(localized: "The capture is no longer authorised."))
        }
        let held = try held(excluding: token)
        let actual = ManualQuota.Item(id: item.id, pages: pages)
        let limits = FieldAssistEntitlement.shared.manualLimits()
        if let reason = ManualQuota.decide(limits: limits, held: held,
                                          replacing: [item.id], adding: [actual]).message {
            throw Failure.refused(reason)
        }
        if item.id.hasPrefix("pending:") { try additions.checkNewManual(limits: limits, now: now) }
        state.reservations[token] = actual
    }

    /// The caller must supply measured proposed files, not publisher page-count claims.
    /// `recordsAdditions: false` is a review (a link preflight): it decides, and spends nothing.
    static func install<T>(manifest: VaultManifest, root: URL, reservation: UUID? = nil,
                           recordsAdditions: Bool = true, _ commit: () throws -> T) throws -> T {
        state.lock.lock(); defer { state.lock.unlock() }
        guard FieldAssistEntitlement.shared.has(.personalManuals) else { throw Failure.refused(MyManualsPaywallCopy.locked) }
        if let reservation, state.reservations[reservation] == nil { throw Failure.refused(String(localized: "This manual capture was cancelled. Photograph it again.")) }
        let ledger = additions
        var spend: ManualAdditionHistoryStore.Pending?
        var undoWindow: TimeInterval = 0
        let at = now
        if let limits = FieldAssistEntitlement.shared.manualLimits() {
            let held = try held(excluding: reservation)
            let adding = try manifest.documents.map { document in
                let path = manifest.documentSourceRelativePath(document) ?? manifest.documentRelativePath(document)
                return ManualQuota.Item(id: identity(manifest.id, document.file), pages: try pageCount(root.appendingPathComponent(path)))
            }
            let replacing = Set(held.filter { $0.id.hasPrefix(manifest.id + "/") }.map(\.id))
            if let message = ManualQuota.decide(limits: limits, held: held,
                                               replacing: replacing, adding: adding).message { throw Failure.refused(message) }
            // After the quota, under the same lock: only identities new to the shelf are proposed,
            // so a reindex, retry or replacement of a held manual is never a new addition.
            let heldIDs = Set(held.map(\.id))
            let fresh = manifest.documents.filter { !heldIDs.contains(identity(manifest.id, $0.file)) }.map {
                (identity: identity(manifest.id, $0.file), original: root.appendingPathComponent(originalRelativePath(manifest, $0)))
            }
            spend = try ledger.prepare(documents: fresh, limits: limits, now: at)
            undoWindow = limits.additions?.undoWindow ?? 0
        }
        let value = try commit()
        // Same critical section as the commit; a cancelled or failed install never gets here.
        if recordsAdditions, let spend { ledger.commit(spend, undoWindow: undoWindow, now: at) }
        if let reservation { state.reservations[reservation] = nil }
        return value
    }
}

enum MyManualsPaywallCopy {
    static let title = "My Manuals"
    static let locked = "My Manuals needs an active subscription. Your files stay on this phone, and you can still remove them."
    static let summary = String(localized: "Keep your manuals. Ask by voice, hear the page cited, and open the source on your phone.")
    static var pageLimits: String {
        let entitlement = FieldAssistEntitlement.shared
        let limits = entitlement.manualLimits() ?? ManualLimits.personal
        return limitDetails(limits)
    }
    static func limitDetails(_ limits: ManualLimits?) -> String {
        guard let limits else { return String(localized: "Your subscription includes an unlimited manual library.") }
        var parts = [String(localized: "Up to \(limits.manuals.formatted()) manuals in your library.")]
        if let pages = limits.pagesPerManual { parts.append(String(localized: "Up to \(pages.formatted()) pages per manual.")) }
        if let pages = limits.totalPages { parts.append(String(localized: "Up to \(pages.formatted()) pages across your library.")) }
        if let additions = limits.additions {
            let days = Int((additions.window / 86_400).rounded())
            parts.append(String(localized: "Up to \(additions.newPerWindow.formatted()) new manuals in any \(days.formatted()) days; your first \(additions.freeFirst.formatted()) manuals, and any manual you've had before, don't count."))
        }
        return parts.joined(separator: " ")
    }
    static let upgrade = String(localized: "Field Assist is a separate service for jobs, trade references and professional tools.")
    static let disclosure = String(localized: "Your manuals are indexed on this phone and excluded from library sharing and export. Selected passages and rendered page images may be sent to your chosen AI provider. Supported local models process content on this phone; available manual tools vary by model. A private record of which manuals you've added — fingerprints and dates, never the manual — syncs through your iCloud.")
    static var all: [String] { [title, locked, summary, pageLimits, upgrade, disclosure] }
}
