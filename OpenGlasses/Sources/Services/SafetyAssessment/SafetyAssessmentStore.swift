import Foundation

/// Persists HECA reports and exposes recent history (docs/plans/safety-assessment.md). A single JSON
/// file under Application Support, newest-first, capped at `maxHistory`. Directory + FileManager are
/// injectable for tests.
@MainActor
final class SafetyAssessmentStore: ObservableObject {
    static let shared = SafetyAssessmentStore()

    @Published private(set) var history: [SafetyReport] = []

    private let directory: URL
    private let fileManager: FileManager
    private let maxHistory: Int

    init(directory: URL? = nil, fileManager: FileManager = .default, maxHistory: Int = 50) {
        self.fileManager = fileManager
        self.maxHistory = maxHistory
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        load()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SafetyAssessments", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    /// Save a report at the head of history (newest first), trimmed to `maxHistory`, and persist.
    func save(_ report: SafetyReport) {
        history.removeAll { $0.id == report.id }
        history.insert(report, at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        persist()
    }

    func clear() {
        history = []
        persist()
    }

    // MARK: - Persistence

    /// True after a read failure on an existing history file — saves are suppressed so the
    /// on-disk data (possibly intact) is never overwritten.
    private var saveBlocked = false

    private func load() {
        switch JSONStore.loadArray(SafetyReport.self, at: fileURL, name: "safety_history") {
        case .loaded(let reports), .recovered(let reports, _):
            history = reports
        case .corrupt:
            history = []   // original preserved in StoreRecovery
        case .unreadable:
            saveBlocked = true
        case .absent:
            break
        }
    }

    private func persist() {
        guard !saveBlocked else {
            PrivacyLog.medical(.safetyAssessment, .saveSkipped)
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            PrivacyLog.medical(.safetyAssessment, .persistFailed, error: SafeErrorSummary(error))
        }
    }
}
