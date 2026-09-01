import SwiftUI
import UIKit

/// Settings → Diagnostics & Support → Export Diagnostics.
///
/// The preview is the consent. Nothing is written to disk until the wearer has been shown the
/// exact bytes — the same string the file receives, built once by `DiagnosticExportBuilder` —
/// and has then chosen to export. Leaving the screen without exporting writes nothing at all.
struct DiagnosticExportView: View {
    @Environment(\.appAccent) private var accent

    @State private var document: DiagnosticExportDocument?
    @State private var lease: DiagnosticExportLease?
    @State private var shareItem: ShareItem?
    @State private var failure: String?

    private let coordinator = DiagnosticExportCoordinator.shared

    var body: some View {
        OGScrollPage {
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
                OGRow("Kept In Memory Only", icon: "memorychip", mutedIcon: true, showsChevron: false) {
                    OGRowValue(value: "This session")
                }
            }

            if let document {
                OGSection(header: "Preview", footer: "This is the file, exactly. Nothing is added after you approve it.") {
                    // Wrapped rather than side-scrolled: the wearer is being asked to read this,
                    // and a line they have to scroll to finish is a line they will not read.
                    Text(document.body)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }

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

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(OGTheme.errorLabel)
            }
        }
        .navigationTitle("Export Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        .onAppear { refresh() }
        .onDisappear { releaseOutstandingLease() }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    // MARK: - Actions

    private func refresh() {
        document = DiagnosticExportBuilder.build(
            entries: DiagnosticRing.shared.entries,
            environment: .current,
            capacity: DiagnosticRing.shared.capacity
        )
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
            failure = "Couldn't prepare the diagnostics file. Try again once the device is unlocked."
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
