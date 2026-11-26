import SwiftUI
import UIKit

/// Settings → Advanced & Support → Export Diagnostics.
///
/// The preview is the consent. Nothing is written to disk until the wearer has been shown the
/// exact bytes — the same string the file receives, built once by `DiagnosticExportBuilder` —
/// and has then chosen to export. Leaving the screen without exporting writes nothing at all.
struct DiagnosticExportView: View {
    @Environment(\.appAccent) private var accent

    @State private var document: DiagnosticExportDocument?
    /// The file split into its lines, once per refresh. The preview draws one row per line in a
    /// lazy stack: the ring holds up to 14,000 events (plus the previous run's), and one `Text`
    /// with all of them froze the screen laying itself out — on arrival and again on every state
    /// change, Export included.
    @State private var previewLines: [String] = []
    @State private var lease: DiagnosticExportLease?
    @State private var shareItem: ShareItem?
    @State private var failure: String?

    private let coordinator = DiagnosticExportCoordinator.shared

    var body: some View {
        // Not `OGScrollPage`: its stack is eager, and the preview must be lazy to stay usable
        // with a full ring. Same canvas, gutters and spacing.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    OGNotice(
                        text: "This is a list of what the app did — event names, counts, durations and outcomes. Your conversations, transcripts, photos, names, locations, medical values, keys and web addresses are not in it, and have no way in: the app's logging has no field that accepts them.",
                        systemImage: "hand.raised"
                    )

                    OGSection(
                        header: "What Gets Exported",
                        footer: "Identifiers that would name a device or a thread appear only as short one-way fingerprints. Marking a log field private hides it from other apps on this device — it does not make a value safe to send us, so this app doesn't put values in log fields at all."
                    ) {
                        OGRow("Events Held", icon: "list.bullet.rectangle", showsChevron: false) {
                            OGRowValue(value: "\(document?.eventCount ?? 0)")
                        }
                        OGDivider()
                        OGRow("Saved Locally", icon: "internaldrive", mutedIcon: true, showsChevron: false) {
                            OGRowValue(value: "Up to \(DiagnosticRing.retentionDays) days")
                        }
                    }

                    // Above the preview, so a long file never puts the button thousands of lines away.
                    exportButton

                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(OGTheme.errorLabel)
                    }

                    if document != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preview")
                                .textCase(.uppercase)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .accessibilityAddTraits(.isHeader)
                            Text("This is the file, exactly. Nothing is added after you approve it.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 20)
                        }
                        .padding(.bottom, 6)
                    }
                }

                if document != nil {
                    previewCap(top: true)
                    // Wrapped rather than side-scrolled: the wearer is being asked to read this,
                    // and a line they have to scroll to finish is a line they will not read.
                    ForEach(previewLines.indices, id: \.self) { index in
                        Text(verbatim: previewLines[index].isEmpty ? " " : previewLines[index])
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .background(OGTheme.card)
                    }
                    previewCap(top: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 44)
        }
        .background(OGTheme.canvas.ignoresSafeArea())
        .navigationTitle("Export Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .onAppear { refresh() }
        .onDisappear { releaseOutstandingLease() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    private var exportButton: some View {
        Button {
            export()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                Text("Export Diagnostics")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(document == nil)
    }

    /// The rounded top or bottom of the preview card, which is drawn a line at a time.
    private func previewCap(top: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: top ? 22 : 0, bottomLeadingRadius: top ? 0 : 22,
            bottomTrailingRadius: top ? 0 : 22, topTrailingRadius: top ? 22 : 0,
            style: .continuous
        )
        .fill(OGTheme.card)
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func refresh() {
        let built = DiagnosticExportBuilder.build(
            entries: DiagnosticRing.shared.entries,
            environment: .current,
            previousEntries: DiagnosticRing.shared.previousEntries,
            capacity: DiagnosticRing.shared.capacity,
            crashNotes: CrashNoteStore.shared.notes,
            lastScreens: LastScreensStore.shared.all,
            currentRun: DiagnosticRing.shared.runID
        )
        document = built
        previewLines = built.body.components(separatedBy: "\n")
    }

    private func export() {
        guard let document else { return }
        releaseOutstandingLease()
        do {
            let made = try coordinator.makeLease(document: document)
            lease = made
            coordinator.beginShare(made)
            shareItem = ShareItem(items: [DiagnosticExportActivityItem(lease: made)]) { completed in
                coordinator.finishShare(made, outcome: completed ? .completed : .cancelled)
                lease = nil
            }
            failure = nil
        } catch {
            failure = String(localized: "Couldn't prepare the diagnostics file. Try again once the device is unlocked.")
        }
    }

    /// A bundle the wearer never handed to a share provider must not outlive the screen.
    private func releaseOutstandingLease() {
        if let lease {
            coordinator.release(lease)
            self.lease = nil
        }
    }
}

extension DiagnosticExportEnvironment {
    /// The running build and hardware. Four facts about the app and the device, none about the
    /// wearer — the same four a crash report carries.
    static var current: DiagnosticExportEnvironment {
        DiagnosticExportEnvironment(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–",
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–",
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareIdentifier
        )
    }

    /// "iPhone17,1" — the hardware model, which is what a triage needs. `UIDevice.model` only ever
    /// says "iPhone".
    private static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
