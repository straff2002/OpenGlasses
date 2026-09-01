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
                        subtitle: "Review what's included, then open an issue"
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

                Button {
                    UIApplication.shared.open(report.issueURL)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline.weight(.semibold))
                        Text("Open a Bug Report")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)

                OGSection(footer: linkFooter) {
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
        }
        .tint(accent)
    }

    private var maskingSummary: String {
        report.redactionHits.isEmpty
            ? "Nothing in this report looked like a key, token, or personal identifier."
            : "Masked before you saw it: \(report.redactionHits.joined(separator: ", "))."
    }

    private var linkFooter: String {
        report.omittedLogLines > 0
            ? "A link can't hold the whole log, so \(report.omittedLogLines) older line\(report.omittedLogLines == 1 ? "" : "s") are left out of the bug-report link. Copy or share to send the complete report."
            : "Copy or share the report if you'd rather send it another way."
    }
}
