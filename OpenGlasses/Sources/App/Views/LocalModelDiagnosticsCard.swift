import SwiftUI

/// The diagnostics card in the local-model manager: what the engine is, what the last on-device run
/// did, and how hot the phone got doing it.
///
/// Every number comes from `LocalRuntimeDiagnostics`, which the runtime writes at the same call
/// sites it writes its log lines — so a bug report's log and this card describe the same run. The
/// card itself computes nothing except the layout.
struct LocalModelDiagnosticsCard: View {

    /// Re-read on a timer rather than observed: samples are recorded from inside the decode loop,
    /// which must not hop to the main actor to publish. Two seconds matches the memory readouts
    /// above it on the same screen.
    private static let refreshInterval: TimeInterval = 2

    let diagnostics: LocalRuntimeDiagnostics

    init(diagnostics: LocalRuntimeDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            let rows = LocalRuntimeDiagnosticsCard.rows(
                sample: diagnostics.latest,
                frameworkDescription: LlamaRuntimeAvailability.engineDescription)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    LabeledContent(row.label) {
                        Text(row.value)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.spokenLabel)
                }
            }
        }
    }
}
