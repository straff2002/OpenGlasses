import SwiftUI
import VisionKit

/// Plan FS §3 — receiving a vault from a link or a QR code, on screen.
///
/// One sheet holds the whole flow, because the flow is one decision made in stages: paste or scan,
/// agree to fetch from the site, watch it download, read what it is, and confirm. The app has no
/// screen anywhere that offers to *send* a vault — no share-as-link, no QR to show somebody, no
/// upload — and `VaultLinkNoShareTests` scrapes the sources to keep it that way.
@MainActor
struct VaultLinkSheet: View {

    @ObservedObject var service: VaultLinkService
    /// Called after a vault installs, so the list behind the sheet reloads.
    var onInstalled: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                switch service.stage {
                case .idle, .failed:
                    entrySection
                case .offer(let offer):
                    offerSection(offer)
                case .downloading(let progress):
                    progressSection(progress)
                case .reviewing(let review):
                    VaultLinkReviewSections(review: review,
                                            acknowledged: $service.acknowledgedUnverified,
                                            install: { Task { await service.confirmInstall() } })
                case .installing:
                    Section { ProgressView().padding(.vertical, 4); Text("Installing…") }
                case .installed(let name):
                    Section {
                        OGStatusLabel("\(name) installed.", kind: .ok)
                        Text("Its manuals are indexed on this phone next; that can take a few minutes for a long one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if case .failed(let message) = service.stage {
                    Section { OGStatusLabel(message, kind: .error) }
                }
            }
            .ogFormStyle()
            .navigationTitle("Add from link or QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(service.stage.isBusy ? "Cancel" : "Close") {
                        service.dismiss()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                VaultLinkScannerSheet { code in
                    scanning = false
                    service.open(code)
                }
            }
            .onChange(of: service.stage) { _, stage in
                if case .installed = stage { onInstalled() }
            }
        }
    }

    // MARK: - Stages

    @ViewBuilder
    private var entrySection: some View {
        Section {
            TextField("https://…", text: $pasted)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Review this link") { service.open(pasted) }
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                scanning = true
            } label: {
                Label("Scan a QR code", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Vault link")
        } footer: {
            Text("Paste the address from the publisher's page, or scan the code they show you. Nothing is downloaded until you have seen which site it comes from, and nothing is installed until you have seen what the vault contains.")
        }
    }

    @ViewBuilder
    private func offerSection(_ offer: VaultLinkService.FetchOffer) -> some View {
        Section {
            LabeledContent("Site", value: offer.host)
            Text(offer.message).font(.callout)
            if offer.isOnCellular {
                OGStatusLabel("You are on cellular data.", kind: .warn)
            }
            Button("Fetch from \(offer.host)") { Task { await service.approveFetch() } }
        } header: {
            Text("Before downloading")
        }
    }

    @ViewBuilder
    private func progressSection(_ progress: VaultLinkService.Progress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(progress.text)
                ProgressView()
            }
        }
    }
}

/// The review itself, split out so the sheet's states stay readable and so the sections can be
/// rendered on their own in a screenshot pass.
@MainActor
struct VaultLinkReviewSections: View {

    let review: VaultLinkReview
    @Binding var acknowledged: Bool
    let install: () -> Void

    var body: some View {
        Section {
            LabeledContent("Vault", value: review.vaultName)
            LabeledContent("Version", value: "v\(review.vaultVersion)")
            LabeledContent("From", value: review.host)
            LabeledContent("Download", value: review.sizeText)
        } header: {
            Text("What this is")
        }

        Section {
            if let signed = review.signedLine {
                OGStatusLabel(signed, kind: .ok, systemImage: "checkmark.seal.fill")
            }
            if review.warningBlock != nil {
                VaultLinkWarningBlock(lines: VaultLinkReview.unverifiedWarning)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            if let refusal = review.refusal {
                OGStatusLabel(refusal, kind: .error)
            }
        }

        Section {
            Text(review.manualsSummary)
            ForEach(review.manuals, id: \.self) { title in
                Label(title, systemImage: "doc.text")
                    .font(.callout)
            }
            Text(VaultLinkReview.groundingSentence)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("What it contains")
        }

        if let note = review.updateNote {
            Section { Text(note).font(.callout) }
        }

        if let cellular = review.cellularWarning {
            Section { OGStatusLabel(cellular, kind: .warn) }
        }

        if review.refusal == nil {
            Section {
                if review.requiresAcknowledgement {
                    Toggle(isOn: $acknowledged) {
                        Text(VaultLinkReview.acknowledgementPrompt)
                            .font(.callout)
                    }
                }
                Button(review.installButtonTitle, action: install)
                    .disabled(!review.allowsInstall(acknowledged: acknowledged))
            }
        }
    }
}

/// The highlighted block an unverified archive shows.
///
/// Drawn from tokens whose contrast is measured rather than judged: the ground is
/// `OGTheme.warnNoticeFill`, the heading and the border are `OGTheme.warnNoticeLabel` — the warn
/// hue corrected against *that ground* rather than against the row behind it — and the sentences
/// are the primary label. `VaultLinkContrastTests` checks all three pairs in both appearances.
struct VaultLinkWarningBlock: View {

    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Unverified source")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OGTheme.warnNoticeLabel)

            ForEach(lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OGTheme.warnNoticeFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OGTheme.warnNoticeLabel, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Unverified source. " + lines.joined(separator: " ")))
    }
}

/// Scanning a publisher's code with the phone's own camera.
///
/// Read-only and single-shot: the first code it recognises is handed back and the scanner closes.
/// The app never *produces* a code — this is the receiving half and there is no other.
@MainActor
struct VaultLinkScannerSheet: View {

    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    VaultLinkScannerView { code in
                        onCode(code)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder").font(.largeTitle)
                        Text("This phone can't scan a code here.")
                        Text("Paste the address from the publisher's page instead, or scan their code with the Camera app — it will open this app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .navigationTitle("Scan a vault code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The live scanner itself. Thin on purpose: everything it recognises goes straight to
/// `VaultLinkPolicy`, which decides whether it is a vault link at all.
struct VaultLinkScannerView: UIViewControllerRepresentable {

    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            deliver(from: addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver(from: [item], scanner: dataScanner)
        }

        private func deliver(from items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                   !text.isEmpty {
                    delivered = true
                    scanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}
