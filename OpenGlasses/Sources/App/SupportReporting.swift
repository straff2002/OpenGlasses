import Foundation
import UIKit

/// The offer made after an AI turn fails: what went wrong, in words, and when.
struct SupportPrompt: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    /// A plain sentence for the banner — never an error's own description.
    let reason: String
}

/// A support report on its way to the review sheet.
struct SupportReportRequest: Identifiable {
    let id = UUID()
    let scope: JobTranscriptExport.Scope
    var options: JobTranscriptExporter.Options
    /// Why the report was started, when an error started it. Shown on the sheet and in the email.
    let reason: String?
}

/// Support reporting (support ask, 2026-09-26): every AI turn is traced, a failed one offers to
/// send a report, and the report is one review sheet away from any of its entry points — the
/// banner, Settings → Diagnostics & Support, and the Job tab.
///
/// Nothing is sent without the person pressing Send: the offer opens a sheet showing the whole
/// file, and Mail or the share sheet does the sending.
extension AppState {

    /// How long a dismissed offer stays quiet. A run of failures while the network is out would
    /// otherwise put the same banner back after every turn.
    static let supportPromptQuietPeriod: TimeInterval = 10 * 60

    /// Point the turn recorder at the trace store, and raise the offer when a turn fails.
    func configureSupportTrace() {
        let store = conversationStore
        TurnRecorder.traceContext = {
            (store.activeThreadId, FieldSessionService.shared.activeSession?.id)
        }
        TurnRecorder.traceSink = { [weak self] timeline in
            let trace = TurnTrace(timeline, sealedAt: Date())
            TurnTraceStore.shared.append(trace)
            if trace.outcome == .failed { self?.offerSupportReport(after: trace) }
        }
    }

    /// Put the banner up for a failed turn, unless the wearer waved it away a moment ago.
    func offerSupportReport(after trace: TurnTrace) {
        if let dismissed = supportPromptDismissedAt,
           Date().timeIntervalSince(dismissed) < Self.supportPromptQuietPeriod { return }
        supportPrompt = SupportPrompt(at: trace.at, reason: Self.plainReason(trace.failure))
    }

    func dismissSupportPrompt() {
        supportPrompt = nil
        supportPromptDismissedAt = Date()
    }

    /// From the banner: the day the failure happened, everything included, ready to review.
    func openSupportReport(from prompt: SupportPrompt) {
        supportPrompt = nil
        let time = prompt.at.formatted(date: .omitted, time: .shortened)
        supportReportRequest = SupportReportRequest(
            scope: .day(prompt.at),
            options: .init(troubleshooting: true, otherConversations: true),
            reason: "An AI turn failed at \(time): \(prompt.reason).")
    }

    /// From Settings or the Job tab.
    func openSupportReport(_ scope: JobTranscriptExport.Scope) {
        let isDay: Bool
        if case .day = scope { isDay = true } else { isDay = false }
        supportReportRequest = SupportReportRequest(
            scope: scope,
            options: .init(troubleshooting: true, otherConversations: isDay),
            reason: nil)
    }

    /// Build the report for the review sheet. Unlocks encrypted conversations first (Face ID).
    func buildSupportReport(_ request: SupportReportRequest) async
        -> Result<JobTranscriptExport.Document, JobTranscriptExporter.Failure> {
        if conversationStore.isLocked {
            _ = await conversationStore.unlock()
        }
        return JobTranscriptExporter.document(request.scope, options: request.options,
                                              sessions: FieldSessionService.shared,
                                              store: conversationStore,
                                              environment: supportEnvironment())
    }

    /// What only the running app knows: the phone, the glasses, the app's event log and the
    /// debug log, and the configured secrets the report is masked with.
    func supportEnvironment() -> JobTranscriptExporter.Environment {
        let info = Bundle.main.infoDictionary
        var phone = [
            "App: \(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "Device: \(Self.hardwareIdentifier)",
            "Language: \(Locale.current.identifier)",
            "Mode: \(currentMode.rawValue)",
            "AI model: \(Config.activeModel?.name ?? "none set")",
            "Transcription preference: \(Config.asrEnginePreference.rawValue)",
        ]
        if isConnected {
            var glasses = "Glasses: connected"
            if let name = glassesService.deviceName { glasses += " — \(name)" }
            if let battery = glassesService.batteryLevel { glasses += ", battery \(battery)%" }
            phone.append(glasses)
            phone.append("Glasses display: \(glassesDisplay.hasDisplayCapability ? "yes" : "no")")
        } else {
            phone.append("Glasses: not connected")
        }
        if let job = FieldSessionService.shared.activeSession, job.endedAt == nil {
            phone.append("Job open: \(job.jobReference.map { "Job \($0)" } ?? JobTabModel.noJobNumber)")
        }
        let ring = DiagnosticRing.shared
        let events = (ring.previousEntries + ring.entries).map {
            JobTranscriptExport.AppEvent(at: $0.timestamp, line: $0.line)
        }
        return .init(phone: phone, appEvents: events, debugLog: Array(debugEvents.suffix(60)),
                     secrets: Config.knownSecretValues)
    }

    /// "Rate-limited by the AI service" rather than `rateLimited#429`, for the banner. The exact
    /// category still travels in the report.
    static func plainReason(_ failure: String?) -> String {
        guard let failure else { return "the AI didn't answer" }
        let category = failure.split(whereSeparator: { $0 == "(" || $0 == "#" }).first.map(String.init) ?? failure
        switch SafeErrorSummary.Category(rawValue: category) {
        case .offline: return "no internet connection"
        case .timedOut: return "the AI service took too long"
        case .cannotConnect, .tlsFailure: return "the AI service couldn't be reached"
        case .unauthorized, .forbidden: return "the AI service refused the key"
        case .rateLimited: return "the AI service was busy (rate-limited)"
        case .serverError: return "the AI service had an error"
        case .decoding, .badServerResponse: return "the AI's reply couldn't be read"
        case .refused: return "the app refused the request"
        default: return "the AI didn't answer"
        }
    }

    /// "iPhone17,1" — the hardware model, which is what triage needs. `UIDevice.model` only ever
    /// says "iPhone".
    static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
