import Foundation

enum CaptureFlowError: LocalizedError {
    case noSession
    case alreadyRunning
    case unknownFlow(String)

    var errorDescription: String? {
        switch self {
        case .noSession:        return "No active Field Assist session. Start a session first."
        case .alreadyRunning:   return "A capture flow is already running. Finish or cancel it first."
        case .unknownFlow(let id): return "Unknown capture flow: \(id)"
        }
    }
}

/// Owns the active `CaptureFlowRunner` for the app (Plan U), mirroring how `FieldSessionService`
/// owns a procedure runner. Loads flows from the active session's vault, drives them through the
/// `capture_flow` tool, and persists the finished `CaptureRecord` to the offline queue (Plan T) so
/// it syncs and folds into the session audit. Returns tool-facing strings; the typed work is in
/// `CaptureFlowRunner`.
@MainActor
final class CaptureFlowService: ObservableObject {
    static let shared = CaptureFlowService()

    /// Persist finished records (set by AppState). Composes with Plan T.
    var offlineQueue: OfflineQueue?
    /// Current GPS for capture provenance (set by AppState).
    var location: (() -> (lat: Double, lon: Double)?)?
    /// region id → inside? for `inside_region` preconditions (set by AppState; nil ⇒ can't tell).
    var insideRegion: ((String) -> Bool?)?

    @Published private(set) var activeFlowId: String?
    private var runner: CaptureFlowRunner?

    private func library() -> CaptureFlowLibrary? {
        FieldSessionService.shared.activeVault.map { CaptureFlowLibrary(store: $0) }
    }

    func availableFlows() -> [String] { library()?.summaries() ?? [] }

    func start(flowId: String, assetId: String?) throws -> String {
        guard FieldSessionService.shared.activeSession != nil, let lib = library() else {
            throw CaptureFlowError.noSession
        }
        guard runner == nil else { throw CaptureFlowError.alreadyRunning }
        guard let flow = lib.flow(id: flowId) else { throw CaptureFlowError.unknownFlow(flowId) }
        let sessionId = FieldSessionService.shared.activeSession!.id

        let r = CaptureFlowRunner(
            flow: flow, sessionId: sessionId, assetId: assetId,
            location: { [weak self] in self?.location?() ?? nil },
            insideRegion: { [weak self] region in self?.insideRegion?(region) ?? nil })
        runner = r
        activeFlowId = flow.id

        var message = "Started '\(flow.title)'."
        let unmet = r.unmetPreconditions()
        if !unmet.isEmpty {
            let warn = unmet.compactMap(\.message).joined(separator: " ")
            message += " ⚠️ \(warn.isEmpty ? "A precondition isn't met." : warn) Proceed anyway, or say cancel."
        }
        return message + "\n" + r.prompt()
    }

    func answer(_ text: String) -> String {
        guard let r = runner else { return "No capture flow is running. Start one first." }
        switch r.answer(text) {
        case .accepted(let next):  return next
        case .rejected(let reason): return reason
        case .finished:            return "All steps captured. Say finish to save the record."
        }
    }

    func skip() -> String {
        guard let r = runner else { return "No capture flow is running." }
        if case .accepted(let next) = r.skip() { return "Skipped. " + next }
        return "All steps captured. Say finish to save the record."
    }

    func back() -> String {
        guard let r = runner else { return "No capture flow is running." }
        if case .accepted(let next) = r.back() { return next }
        return r.prompt()
    }

    func status() -> String {
        runner?.status() ?? "No capture flow is running."
    }

    func finish() -> String {
        guard let r = runner else { return "No capture flow is running." }
        switch r.finish() {
        case .missingRequired(let fields):
            return "Can't finish yet — these required fields are still missing: \(fields.joined(separator: ", "))."
        case .completed(let record):
            persist(record)
            runner = nil
            activeFlowId = nil
            let n = record.fields.count
            return "Saved '\(record.flowId)' — \(n) field\(n == 1 ? "" : "s") captured\(offlineQueue == nil ? "" : " and queued to sync")."
        }
    }

    func cancel() -> String {
        guard runner != nil else { return "No capture flow is running." }
        runner = nil
        activeFlowId = nil
        return "Capture flow cancelled."
    }

    private func persist(_ record: CaptureRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        offlineQueue?.enqueue(QueuedOp(kind: .logEntry, sessionId: record.sessionId, payload: data))
    }
}
