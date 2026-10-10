import Foundation
import UIKit

/// The offer made after an AI turn fails: what went wrong, in words, and when.
struct SupportPrompt: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    /// A plain sentence for the banner — never an error's own description.
    let reason: String
    /// The conversation the failed turn belonged to, when it had one.
    var threadId: String? = nil
}

/// A support report on its way to the review sheet.
struct SupportReportRequest: Identifiable {
    let id = UUID()
    var scope: JobTranscriptExport.Scope
    var options: JobTranscriptExporter.Options
    /// Why the report was started, when an error started it. Shown on the sheet and in the email.
    let reason: String?
    /// The day this report can be widened to on the sheet, when it opened on one conversation
    /// after a failed turn. Nil everywhere else: the other entry points each name their scope.
    var widerDay: Date? = nil

    /// From Settings or the Job tab: the scope asked for, with the troubleshooting layer. A day
    /// carries the conversations outside its jobs unless the person turns that off on the sheet.
    static func named(_ scope: JobTranscriptExport.Scope) -> SupportReportRequest {
        let isDay: Bool
        if case .day = scope { isDay = true } else { isDay = false }
        return SupportReportRequest(
            scope: scope,
            options: .init(troubleshooting: true, otherConversations: isDay),
            reason: nil)
    }

    /// After a failed turn: the conversation the turn belonged to, with the whole day one switch
    /// away on the sheet. A turn recorded against no conversation opens the day, as every failed
    /// turn did before conversations could be sent alone.
    ///
    /// The conversation is the default because the person pressing Send has one failure in mind,
    /// and the report that answers it should not carry everything else they said that day.
    /// Widening to the day keeps "everything included", which is what the banner always sent.
    static func afterFailedTurn(at: Date, threadId: String?, reason: String) -> SupportReportRequest {
        let everything = JobTranscriptExporter.Options(troubleshooting: true, otherConversations: true)
        guard let threadId else {
            return SupportReportRequest(scope: .day(at), options: everything, reason: reason)
        }
        return SupportReportRequest(scope: .conversation(threadId: threadId), options: everything,
                                    reason: reason, widerDay: at)
    }

    /// The most recent conversation on the phone, or nil when nothing has been said yet.
    static func lastConversation(in threads: [ConversationThread]) -> SupportReportRequest? {
        JobTranscriptExport.lastConversation(in: threads).map {
            SupportReportRequest.named(.conversation(threadId: $0.id))
        }
    }
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
        supportPrompt = SupportPrompt(at: trace.at,
                                      reason: Self.plainReason(trace.failure, rejection: trace.rejectionReason),
                                      threadId: trace.threadId)
    }

    func dismissSupportPrompt() {
        supportPrompt = nil
        supportPromptDismissedAt = Date()
    }

    /// From the banner: the conversation the failure happened in, ready to review, with the whole
    /// day one switch away (`SupportReportRequest.afterFailedTurn`).
    func openSupportReport(from prompt: SupportPrompt) {
        supportPrompt = nil
        let time = prompt.at.formatted(date: .omitted, time: .shortened)
        supportReportRequest = .afterFailedTurn(
            at: prompt.at, threadId: prompt.threadId,
            reason: "An AI turn failed at \(time): \(prompt.reason).")
    }

    /// From Settings or the Job tab.
    func openSupportReport(_ scope: JobTranscriptExport.Scope) {
        supportReportRequest = .named(scope)
    }

    /// Why "Send Last Conversation" did not open the review sheet.
    enum LastConversationProblem: Equatable {
        /// Conversations are encrypted and Face ID did not unlock them.
        case locked
        case noConversation
    }

    /// From Settings: the most recent conversation, and nothing else from the day.
    ///
    /// Which conversation is the last one cannot be known while conversations are locked, so they
    /// are unlocked first (Face ID) — the same unlock the review sheet would ask for a moment
    /// later. Returns what stopped it, or nil once the sheet is up.
    func openSupportReportForLastConversation() async -> LastConversationProblem? {
        if conversationStore.isLocked {
            guard await conversationStore.unlock() else { return .locked }
        }
        guard let request = SupportReportRequest.lastConversation(in: conversationStore.threads) else {
            return .noConversation
        }
        supportReportRequest = request
        return nil
    }

    /// Build the report for the review sheet. Unlocks encrypted conversations first (Face ID).
    func buildSupportReport(_ request: SupportReportRequest) async
        -> Result<JobTranscriptExport.Document, JobTranscriptExporter.Failure> {
        if conversationStore.isLocked {
            _ = await conversationStore.unlock()
        }
        let storefront = await StoreKitStorefrontReader().countryCode()
        return JobTranscriptExporter.document(request.scope, options: request.options,
                                              sessions: FieldSessionService.shared,
                                              store: conversationStore,
                                              environment: supportEnvironment(storefront: storefront))
    }

    /// Whether this phone belongs to an organisation: set up by a profile, or running on an
    /// organisation licence. Support reports from these phones never go to the developer.
    var isOrganisationPhone: Bool {
        OrgProfileManager.shared.isManaged || LicenseService.shared.activeLicense != nil
    }

    /// Where a support report from this phone is emailed, or nil when an organisation phone has
    /// no support address and no job-report office to fall back on.
    var supportReportRecipient: String? {
        SupportReportRecipient.resolve(configured: Config.supportReportEmail,
                                       organisationPhone: isOrganisationPhone,
                                       organisationRecipients: Config.organizationReportRecipients)
    }

    /// What only the running app knows: the phone, the glasses, the app's event log and the
    /// debug log, and the configured secrets the report is masked with.
    ///
    /// `storefront` is the App Store country as alpha-2 (`StorefrontReader`), read by the caller
    /// because StoreKit answers asynchronously. A country code, not personal data.
    func supportEnvironment(storefront: String? = nil) -> JobTranscriptExporter.Environment {
        let app = AppBuildIdentity.current
        var phone = [
            "App: \(app.version) (\(app.build))",
            "Source: " + (app.commit.map { "\($0) when the Xcode project was generated" } ?? "not stamped"),
            "Installed from: \(app.channel.rawValue) (\(app.bundleID))",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "Device: \(Self.hardwareIdentifier)",
            // The app's language and region, then the phone's own list: `en_MX` alone cannot say
            // whether the phone is in English or in a language the app does not ship.
            "Language: \(Locale.current.identifier)",
            "Phone languages: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))",
            // Which market the app was distributed in — what a region-dependent capability will turn on.
            MarketAvailabilityPolicy.supportReportLine(storefront: storefront),
            "Mode: \(currentMode.rawValue)",
            "AI model: \(Config.activeModel?.name ?? "none set")",
            "Transcription preference: \(Config.asrEnginePreference.rawValue)",
        ]
        if isConnected {
            var glasses = "Glasses: connected"
            // A pair the SDK has not named yet reports an empty name, not a missing one.
            if let name = glassesService.deviceName?.trimmingCharacters(in: .whitespaces),
               !name.isEmpty {
                glasses += " — \(name)"
            }
            if let battery = glassesService.batteryLevel { glasses += ", battery \(battery)%" }
            phone.append(glasses)
            phone.append("Glasses display: \(glassesDisplay.hasDisplayCapability ? "yes" : "no")")
        } else {
            phone.append("Glasses: not connected")
            // Which kind of not connected (Plan HX P3): never added, waiting on the camera
            // permission, listed and out of reach. Case names and a count; no device is named.
            phone.append(glassesService.reachability.reportLine)
        }
        if let job = FieldSessionService.shared.activeSession, job.endedAt == nil {
            phone.append("Job open: \(job.jobReference.map { "Job \($0)" } ?? JobTabModel.noJobNumber)")
        }
        let ring = DiagnosticRing.shared
        let events = (ring.previousEntries + ring.entries).map {
            JobTranscriptExport.AppEvent(at: $0.timestamp, line: $0.line)
        }
        return .init(phone: phone, app: app.summary, appEvents: events, debugLog: Array(debugEvents.suffix(60)),
                     secrets: Config.knownSecretValues)
    }

    /// "Rate-limited by the AI service" rather than `rateLimited#429`, for the banner. The exact
    /// category still travels in the report.
    ///
    /// `rejection` is the reason a provider's refusal classified as (`ProviderRejection.Reason`,
    /// by raw value). It refines a refused request into what the wearer can do about it: a model
    /// that does not take what the app sent is a different model's job; a credential that was
    /// not accepted is a key to check or a sign-in to repeat.
    static func plainReason(_ failure: String?, rejection: String? = nil) -> String {
        guard let failure else { return "the AI didn't answer" }
        let category = failure.split(whereSeparator: { $0 == "(" || $0 == "#" }).first.map(String.init) ?? failure
        let reason = rejection.flatMap(ProviderRejection.Reason.init(rawValue:))
        switch SafeErrorSummary.Category(rawValue: category) {
        case .clientError, .unauthorized, .forbidden:
            if reason?.isModelContract == true {
                return "the AI service rejected the request — this model doesn't accept it, so try another model"
            }
            if reason == .credentialNotAccepted || reason == .betaHeaderUnknown {
                return "the AI service didn't accept the key or sign-in — check the key, or sign in again"
            }
            return category == SafeErrorSummary.Category.clientError.rawValue
                ? "the AI service rejected the request"
                : "the AI service refused the key"
        case .offline: return "no internet connection"
        case .timedOut: return "the AI service took too long"
        case .cannotConnect, .tlsFailure: return "the AI service couldn't be reached"
        case .rateLimited: return "the AI service was busy (rate-limited)"
        case .serverError: return "the AI service had an error"
        case .decoding, .badServerResponse: return "the AI's reply couldn't be read"
        case .modelDeclined: return "the AI declined to answer that — rephrase it, or try another model"
        case .outputTruncated: return "the AI ran out of room before it answered — try again, or lower the model's reasoning setting"
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
