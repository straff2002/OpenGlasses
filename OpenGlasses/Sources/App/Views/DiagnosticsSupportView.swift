import SwiftUI
import UIKit

/// Settings → Diagnostics & Support: the self-test and the bug-report path.
///
/// Deliberately a top-level category rather than a page inside Advanced, because
/// Simple Mode hides Advanced — and the wearers most likely to need diagnostics are
/// exactly the ones who never see the Developer panel. Same six probes, plus a
/// report the wearer reads in full before any of it leaves the device.
struct DiagnosticsSupportView: View {
    @ObservedObject var appState: AppState
    @StateObject private var runner: SubsystemTestRunner
    @Environment(\.appAccent) private var accent

    @State private var report: DiagnosticsReport?
    @State private var showingReport = false
    @State private var copied = false
    @State private var turnRecordsCleared = false
    /// Where support reports go. Empty means the developer's support address.
    @AppStorage("supportReportEmail") private var supportEmail: String = ""

    init(appState: AppState) {
        self.appState = appState
        _runner = StateObject(wrappedValue: SubsystemProbes.makeRunner(appState: appState))
    }

    var body: some View {
        OGScrollPage {
            OGNotice(
                text: "Nothing is ever sent on its own. A report is built only when you ask for one, and you see every line of it before you share it.",
                systemImage: "hand.raised"
            )

            OGSection(
                header: "Send to Support",
                footer: "Today's conversations — in jobs and out of them — with each AI turn's details: which model answered, the manual pages and photos that went with it, how long it took and whether it failed. Plus this phone, the glasses and the app's event log. Keys are masked, and you read it all before you send it. Reports are emailed to the support email above."
            ) {
                supportEmailField
                OGDivider()
                Button {
                    appState.openSupportReport(.day(Date()))
                } label: {
                    OGRow(
                        "Send Today's Activity", icon: "paperplane",
                        subtitle: "Review it, then email it to support"
                    )
                }
                .buttonStyle(.plain)
            }

            OGSection(
                header: "Self-Test",
                footer: "Each check exercises the real path — the camera takes a photo, the AI answers a tiny query, the lens renders a card."
            ) {
                ForEach(Array(runner.tests.enumerated()), id: \.element.id) { index, test in
                    if index > 0 { OGDivider() }
                    Button {
                        Task { await runner.run(test.id) }
                    } label: {
                        OGRow(test.name, icon: test.icon, showsChevron: false) {
                            trailingState(for: test.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(runner.running.contains(test.id))
                }

                if let failure = runner.lastFailure {
                    OGDivider()
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.errorLabel)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }

            Button {
                Task { await runner.runAll() }
            } label: {
                HStack(spacing: 8) {
                    if runner.isRunning {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "stethoscope")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(runner.isRunning ? "Running…" : "Run Diagnostics")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(runner.isRunning ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(accent), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(runner.isRunning)

            OGSection(
                header: "Report a Problem",
                footer: "A report carries your app and iOS versions, device model, language, glasses connection, and the recent debug log. Keys and personal identifiers are masked automatically. Your conversations, contacts, location, and saved memories are never included."
            ) {
                Button {
                    presentReport()
                } label: {
                    OGRow(
                        "Report a Problem", icon: "ladybug",
                        subtitle: "Review what's included, then email it or open an issue"
                    )
                }
                .buttonStyle(.plain)
                OGDivider()
                Button {
                    copyReport()
                } label: {
                    OGRow("Copy Report", icon: "doc.on.doc", mutedIcon: true, showsChevron: false) {
                        OGRowValue(value: copied ? "Copied" : nil)
                    }
                }
                .buttonStyle(.plain)
            }

            OGSection(
                header: "Diagnostics File",
                footer: "A list of what the app did — event names, counts, durations and outcomes from this session only. You read the whole file before it is written, and it is deleted as soon as you've sent it."
            ) {
                NavigationLink {
                    DiagnosticExportView()
                } label: {
                    OGRow(
                        "Export Diagnostics", icon: "doc.text.magnifyingglass",
                        subtitle: "Preview every line, then share the file"
                    )
                }
                .buttonStyle(.plain)
                OGDivider()
                Button {
                    TurnTraceStore.shared.removeAll()
                    turnRecordsCleared = true
                } label: {
                    OGRow("Delete AI Turn Records", icon: "trash", mutedIcon: true,
                          subtitle: "Kept on this phone for 14 days for support reports. No words — only models, timings, manual pages and errors.",
                          showsChevron: false) {
                        OGRowValue(value: turnRecordsCleared ? "Deleted" : nil)
                    }
                }
                .buttonStyle(.plain)
            }

            OGSection(footer: "The Discord is the fastest way to ask a question or share what you've built.") {
                Button {
                    UIApplication.shared.open(Self.discordURL)
                } label: {
                    OGRow("Discord", icon: "bubble.left.and.bubble.right", showsChevron: false) {
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Diagnostics & Support")
        .tint(accent)
        .sheet(isPresented: $showingReport) {
            if let report {
                DiagnosticsReportSheet(report: report)
            }
        }
    }

    /// The support email, typed once and used by every support report on this phone.
    ///
    /// On an organisation's phone the empty field says the organisation's address is needed, and
    /// nothing falls back to the developer (`SupportReportRecipient`).
    private var supportEmailField: some View {
        let trimmed = supportEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let organisation = appState.isOrganisationPhone
        let fallback = SupportReportRecipient.resolve(
            configured: "", organisationPhone: organisation,
            organisationRecipients: Config.organizationReportRecipients)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Support email")
                .font(.subheadline.weight(.semibold))
            TextField(organisation ? "Your organisation's support address" : DiagnosticsReportBuilder.supportEmail,
                      text: $supportEmail)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityHint("Where support reports from this phone are emailed.")
            if !trimmed.isEmpty && !SupportReportRecipient.isPlausible(trimmed) {
                Text(verbatim: fallback.map { "That doesn't look like an email address, so reports will go to \($0) until it's fixed." }
                     ?? "That doesn't look like an email address. Reports can only be shared until it's fixed.")
                    .font(.caption)
                    .foregroundStyle(OGTheme.warnLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else if trimmed.isEmpty {
                Text(verbatim: fallback.map { "Empty: reports go to \($0)." }
                     ?? "Empty: this phone belongs to an organisation, so reports can only be shared until its support address is added.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func trailingState(for id: String) -> some View {
        if runner.running.contains(id) {
            ProgressView()
        } else if let outcome = runner.outcomes[id] {
            HStack(spacing: 6) {
                if outcome.passed {
                    Text("\(outcome.detail) · \(SubsystemTestRunner.format(outcome.seconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.passed ? OGTheme.ok : OGTheme.error)
            }
        } else {
            Image(systemName: "play.circle")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Report

    private static let discordURL = URL(string: "https://discord.gg/8W2qaXJzz9")!

    private func presentReport() {
        report = makeReport()
        showingReport = true
    }

    private func copyReport() {
        let made = makeReport()
        report = made
        UIPasteboard.general.string = made.body
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// The live edge of the report: read the device facts once, hand them to the
    /// pure builder. `knownSecretValues` never appears in the output — it is the
    /// literal-match list the redactor scrubs *with*.
    private func makeReport() -> DiagnosticsReport {
        let snapshot = DiagnosticsSnapshot(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–",
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: Self.hardwareIdentifier,
            localeIdentifier: Locale.current.identifier,
            glassesConnected: appState.isConnected,
            glassesName: appState.glassesService.deviceName,
            glassesBatteryPercent: appState.glassesService.batteryLevel,
            hasDisplayCapability: appState.glassesDisplay.hasDisplayCapability,
            activeModelName: Config.activeModel?.name,
            logTail: appState.debugEvents,
            selfTestSummary: SubsystemProbes.summary(of: runner)
        )
        return DiagnosticsReportBuilder.build(snapshot, redacting: Config.knownSecretValues)
    }

    /// "iPhone17,1" — the hardware model, which is what a crash triage needs.
    /// `UIDevice.model` only ever says "iPhone".
    private static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

// MARK: - Report sheet

/// The report, in full, before anything leaves the device. Reading it is the point:
/// the wearer approves the actual text, not a promise about it.
private struct DiagnosticsReportSheet: View {
    let report: DiagnosticsReport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var copied = false
    @State private var showingMail = false
    @State private var shareItem: ShareItem?
    @State private var emailStatus: EmailStatus?

    /// What the sheet says after Email Report was tapped. Nil until then.
    private enum EmailStatus: Equatable {
        /// No Mail account: the report went to the share sheet instead.
        case sharedInstead
        case finished(DiagnosticsEmailOutcome)
    }

    private var draft: DiagnosticsEmailDraft { DiagnosticsEmailDraft(report: report) }

    var body: some View {
        NavigationStack {
            OGScrollPage {
                OGNotice(text: maskingSummary, systemImage: "eye.slash")

                OGSection(header: "Report") {
                    Text(report.body)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }

                VStack(spacing: 8) {
                    Button {
                        emailReport()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope")
                                .font(.subheadline.weight(.semibold))
                            Text("Email Report")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(accent, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Text("Goes to \(DiagnosticsReportBuilder.supportEmail). No account needed, and you can add to it before you send.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if let emailStatus {
                        statusLabel(for: emailStatus)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                OGSection(footer: linkFooter) {
                    Button {
                        UIApplication.shared.open(report.issueURL)
                    } label: {
                        OGRow(
                            "Open a GitHub Issue", icon: "arrow.up.right.square", mutedIcon: true,
                            subtitle: "Needs a GitHub account", showsChevron: false
                        ) {
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    OGDivider()
                    Button {
                        UIPasteboard.general.string = report.body
                        copied = true
                    } label: {
                        OGRow("Copy Report", icon: "doc.on.doc", mutedIcon: true, showsChevron: false) {
                            OGRowValue(value: copied ? "Copied" : nil)
                        }
                    }
                    .buttonStyle(.plain)
                    OGDivider()
                    ShareLink(item: report.body, subject: Text(report.title)) {
                        OGRow("Share Report", icon: "square.and.arrow.up", mutedIcon: true, showsChevron: false) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Review Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingMail) {
                DiagnosticsReportMailComposer(draft: draft) { outcome in
                    showingMail = false
                    emailStatus = .finished(outcome)
                }
                .ignoresSafeArea()
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: item.items, onComplete: item.onComplete)
            }
        }
        .tint(accent)
    }

    // MARK: - Email

    private func emailReport() {
        switch DiagnosticsReportMailComposer.route {
        case .mailComposer:
            emailStatus = nil
            showingMail = true
        case .shareSheet:
            emailStatus = .sharedInstead
            shareItem = ShareItem(items: [DiagnosticsEmailActivityItem(draft: draft)])
        }
    }

    @ViewBuilder
    private func statusLabel(for status: EmailStatus) -> some View {
        switch status {
        case .sharedInstead:
            OGStatusLabel(
                "This device has no Mail account set up, so the report opened in the share sheet. Send it to \(DiagnosticsReportBuilder.supportEmail).",
                kind: .warn, systemImage: "envelope.badge"
            )
        case .finished(.sent):
            OGStatusLabel("Report sent. Thank you.", kind: .ok)
        case .finished(.saved):
            OGStatusLabel("Saved to your Mail drafts. It hasn't been sent yet.", kind: .warn)
        case .finished(.cancelled):
            OGStatusLabel("Not sent.", kind: .warn, systemImage: "xmark.circle")
        case .finished(.failed):
            OGStatusLabel("Mail couldn't send the report. Copy or share it instead.", kind: .error)
        }
    }

    // `LocalizedStringKey` rather than `String`, so these sentences reach the
    // string catalog with their interpolations as format specifiers.
    private var maskingSummary: LocalizedStringKey {
        report.redactionHits.isEmpty
            ? "Nothing in this report looked like a key, token, or personal identifier."
            : "Masked before you saw it: \(report.redactionHits.joined(separator: ", "))."
    }

    private var linkFooter: LocalizedStringKey {
        if report.omittedLogLines > 0 {
            return "A link can't hold the whole log, so \(report.omittedLogLines) older \(report.omittedLogLines == 1 ? "line is" : "lines are") left out of the GitHub issue link. Email, copy or share to send the complete report."
        }
        return "Copy or share the report if you'd rather send it another way."
    }
}
