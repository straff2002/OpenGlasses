import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// Hears about crashes from the system and keeps a `CrashNote` for each (Plan MB).
///
/// MetricKit delivers a crash's diagnostic on a later launch — a local hand-over from the OS, not
/// a transmission. On by default in every build and channel (the owner's decision, 2026-11-26):
/// nothing is collected off the phone, and a note leaves it only inside a report the person
/// reviews and sends.
///
/// Up to iOS 26 the delivery is `MXMetricManagerSubscriber`; from iOS 27 the newer API's
/// `MetricManager.diagnosticReports` is read as well. Both make the same `CrashNote`, and the
/// store keeps one note per fingerprint, so a crash that arrives both ways is kept once.
final class CrashDiagnosticsSubscriber: NSObject, @unchecked Sendable {

    static let shared = CrashDiagnosticsSubscriber()

    private let lock = NSLock()
    private var started = false
    private var onNewNotes: (@Sendable () -> Void)?
    #if canImport(MetricKit)
    private var reportTask: Task<Void, Never>?
    #endif

    /// Subscribe, once per process. `onNewNotes` runs on an arbitrary thread whenever a delivery
    /// added a note; it must hop to the main actor itself.
    func start(store: CrashNoteStore = .shared, onNewNotes: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        self.onNewNotes = onNewNotes
        lock.unlock()
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        // Payloads the system delivered while the app was not subscribed.
        receive(MXMetricManager.shared.pastDiagnosticPayloads, store: store)
        // The newer API is in the iOS 27 SDK only (Xcode 27, Swift 6.4); see `CrashNote(crash:…)`.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let manager = MetricManager()
            reportTask = Task.detached(priority: .utility) { [weak self] in
                for await report in manager.diagnosticReports {
                    guard case .crash(let crash) = report.result else { continue }
                    let environment = report.environment
                    let note = CrashNote(crash: crash, appVersion: environment.applicationVersion,
                                         build: environment.applicationBuildVersion,
                                         osVersion: "\(environment.osVersion.platform) \(environment.osVersion.number) (\(environment.osVersion.buildNumber))",
                                         window: report.timeRange)
                    self?.keep([note], store: store)
                }
            }
        }
        #endif
        #endif
    }

    #if canImport(MetricKit)
    private func receive(_ payloads: [MXDiagnosticPayload], store: CrashNoteStore) {
        let notes = payloads.flatMap { CrashNote.notes(fromPayloadJSON: $0.jsonRepresentation()) }
        keep(notes, store: store)
    }
    #endif

    private func keep(_ notes: [CrashNote], store: CrashNoteStore) {
        guard !notes.isEmpty else { return }
        let added = store.add(notes)
        guard !added.isEmpty else { return }
        PrivacyLog.app(.crashNoteReceived, count: added.count)
        lock.lock()
        let callback = onNewNotes
        lock.unlock()
        callback?()
    }
}

#if canImport(MetricKit)
extension CrashDiagnosticsSubscriber: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        receive(payloads, store: .shared)
    }
}
#endif
